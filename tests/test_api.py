""" Tests for API endpoints """
from io import BytesIO

from mock import MagicMock, PropertyMock, patch
from pyramid.httpexceptions import HTTPBadRequest, HTTPForbidden
from pyramid.testing import DummyRequest

from pypicloud.views import api

from . import MockServerTest, make_dist, make_package


class TestApi(MockServerTest):

    """Tests for API endpoints"""

    def setUp(self):
        super(TestApi, self).setUp()
        self.access = self.request.access = MagicMock()
        self.request.registry.stream_files = False
        self.request.registry.package_max_age = 0

    def test_list_packages(self):
        """List all packages"""
        p1 = make_package()
        self.db.upload(p1.filename, BytesIO(b"test1234"))
        pkgs = api.all_packages(self.request)
        self.assertEqual(pkgs["packages"], [p1.name])

    def test_list_packages_no_perm(self):
        """If no read permission, package not in all_packages"""
        p1 = make_package()
        self.db.upload(p1.filename, BytesIO(b"test1234"))
        self.access.has_permission.return_value = False
        pkgs = api.all_packages(self.request)
        self.assertEqual(pkgs["packages"], [])

    def test_list_packages_verbose(self):
        """List all package data"""
        p1 = make_package()
        p1 = self.db.upload(p1.filename, BytesIO(b"test1234"))
        pkgs = api.all_packages(self.request, True)
        self.assertEqual(
            pkgs["packages"],
            [{"name": p1.name, "summary": None, "last_modified": p1.last_modified}],
        )

    def test_delete_missing(self):
        """Deleting a missing package raises 400"""
        context = MagicMock()
        context.name = "pkg1"
        context.version = "1.1"
        ret = api.delete_package(context, self.request)
        self.assertTrue(isinstance(ret, HTTPBadRequest))

    def test_register_not_allowed(self):
        """If registration is disabled, register() returns 404"""
        self.request.named_subpaths = {"username": "a"}
        self.access.allow_register.return_value = False
        self.access.need_admin.return_value = False
        ret = api.register(self.request, "b")
        self.assertTrue(isinstance(ret, HTTPForbidden))

    def test_register(self):
        """Registration registers user with access backend"""
        self.request.named_subpaths = {"username": "a"}
        self.access.need_admin.return_value = False
        self.access.user_data.return_value = None
        self.access.pending_users.return_value = []
        api.register(self.request, "b")
        self.access.register.assert_called_with("a", "b")

    def test_register_set_admin(self):
        """If access needs admin, first registered user is set as admin"""
        self.request.named_subpaths = {"username": "a"}
        self.access.need_admin.return_value = True
        self.access.user_data.return_value = None
        self.access.pending_users.return_value = []
        api.register(self.request, "b")
        self.access.register.assert_called_with("a", "b")
        self.access.approve_user.assert_called_with("a")
        self.access.set_user_admin.assert_called_with("a", True)

    def test_change_password(self):
        """Change password forwards to access"""
        with patch.object(
            DummyRequest, "authenticated_userid", new_callable=PropertyMock
        ) as auid:
            auid.return_value = "u"
            api.change_password(self.request, "a", "b")
            self.access.edit_user_password.assert_called_with("u", "b")

    def test_change_password_no_verify(self):
        """Change password fails if invalid credentials"""
        with patch.object(
            DummyRequest, "authenticated_userid", new_callable=PropertyMock
        ) as auid:
            auid.return_value = "u"
            self.access.verify_user.return_value = False
            ret = api.change_password(self.request, "a", "b")
            self.assertTrue(isinstance(ret, HTTPForbidden))
            self.access.verify_user.assert_called_with("u", "a")

    def test_download(self):
        """Downloading package returns download response from db"""
        db = self.request.db = MagicMock()
        context = MagicMock()
        ret = api.download_package(context, self.request)
        db.fetch.assert_called_with(context.filename)
        db.download_response.assert_called_with(db.fetch())
        self.assertEqual(ret, db.download_response())

    def test_download_with_stream_files(self):
        """Downloading package returns download response from db with max age"""
        db = self.request.db = MagicMock()
        data = MagicMock()
        db.storage.open.return_value.__enter__.return_value = data
        data.read.return_value = b""
        self.request.registry.stream_files = True
        self.request.registry.package_max_age = 30
        context = MagicMock()
        ret = api.download_package(context, self.request)
        db.fetch.assert_called_with(context.filename)
        db.storage.open.assert_called_once_with(db.fetch())
        db.download_response.assert_not_called()
        self.assertDictContainsSubset(
            {"Cache-Control": "public, max-age=30"}, ret.headers
        )

    def test_download_fallback_no_cache(self):
        """Downloading missing package on non-'cache' fallback returns 404"""
        db = self.request.db = MagicMock()
        self.request.registry.fallback = "none"
        db.fetch.return_value = None
        context = MagicMock()
        ret = api.download_package(context, self.request)
        self.assertEqual(ret.status_code, 404)

    def test_download_fallback_cache_no_perm(self):
        """Downloading missing package without cache perm returns 403"""
        db = self.request.db = MagicMock()
        self.request.registry.fallback = "cache"
        self.request.access.can_update_cache.return_value = False
        db.fetch.return_value = None
        context = MagicMock()
        ret = api.download_package(context, self.request)
        self.assertEqual(ret, self.request.forbid())

    def test_download_fallback_cache_missing(self):
        """If fallback url is missing dist, return 404"""
        db = self.request.db = MagicMock()
        locator = self.request.locator = MagicMock()
        self.request.registry.fallback = "cache"
        self.request.registry.fallback_url = "http://pypi.com"
        self.request.access.can_update_cache.return_value = True
        db.fetch.return_value = None
        context = MagicMock()
        locator().get_project.return_value = {context.filename: None, "urls": {}}
        ret = api.download_package(context, self.request)
        self.assertEqual(ret.status_code, 404)

    @patch("pypicloud.views.api.fetch_dist")
    def test_download_fallback_cache(self, fetch_dist):
        """Downloading missing package caches result from fallback"""
        db = self.request.db = MagicMock()
        locator = self.request.locator = MagicMock()
        self.request.registry.fallback = "cache"
        self.request.fallback_simple = "https://pypi.org/simple"
        self.request.access.can_update_cache.return_value = True
        db.fetch.return_value = None
        fetch_dist.return_value = (MagicMock(), b"fds")
        context = MagicMock()
        context.filename = "package.tar.gz"
        url = "https://pypi.org/simple/%s" % context.filename
        dist = make_dist(url=url)
        locator.get_releases.return_value = [dist]
        ret = api.download_package(context, self.request)
        fetch_dist.assert_called_with(
            self.request,
            dist["url"],
            dist["name"],
            dist["version"],
            dist["summary"],
            dist["requires_python"],
        )
        self.assertEqual(ret.body, fetch_dist()[1])
        self.assertDictContainsSubset(
            {"Cache-Control": "public, max-age=0"}, ret.headers
        )

    @patch("pypicloud.views.api.fetch_dist")
    def test_download_fallback_cache_max_age(self, fetch_dist):
        """Downloading missing package caches result from fallback"""
        db = self.request.db = MagicMock()
        locator = self.request.locator = MagicMock()
        self.request.registry.fallback = "cache"
        self.request.fallback_simple = "https://pypi.org/simple"
        self.request.access.can_update_cache.return_value = True
        self.request.registry.package_max_age = 30
        db.fetch.return_value = None
        fetch_dist.return_value = (MagicMock(), b"abc")
        context = MagicMock()
        context.filename = "package.tar.gz"
        url = "https://pypi.org/simple/%s" % context.filename
        dist = make_dist(url=url)
        locator.get_releases.return_value = [dist]
        ret = api.download_package(context, self.request)
        fetch_dist.assert_called_once()
        self.assertEqual(ret.body, fetch_dist()[1])
        self.assertDictContainsSubset(
            {"Cache-Control": "public, max-age=30"}, ret.headers
        )
