import re
import unittest
from pathlib import Path

from orchestrator.release_helpers import ReleaseContractError, windows_store_artifact_names


class ReleaseAssetContractTest(unittest.TestCase):
    """Keeps website download suffixes synchronized with release outputs."""

    def test_linux_release_builds_both_architectures_with_stable_artifact_names(self):
        """The website can resolve Linux x64 and arm64 only if both are built distinctly."""
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github/workflows/desktop-direct-builds.yml").read_text()
        build_script = (root / "ui/scripts/build_deb.sh").read_text()
        release_docs = (root / "ui/RELEASING.md").read_text()

        self.assertIn("runner: ubuntu-24.04-arm", workflow)
        self.assertIn("package_arch: amd64", workflow)
        self.assertIn("package_arch: arm64", workflow)
        self.assertIn(
            "name: deploydash-ubuntu-deb-${{ matrix.package_arch }}",
            workflow,
        )
        self.assertIn('amd64) FLUTTER_ARCH="x64"', build_script)
        self.assertIn('arm64) FLUTTER_ARCH="arm64"', build_script)
        self.assertIn("Unsupported Debian package architecture", build_script)
        self.assertIn(
            'BUNDLE_DIR="${APP_DIR}/build/linux/${FLUTTER_ARCH}/release/bundle"',
            build_script,
        )
        self.assertIn("`_amd64.deb`", release_docs)
        self.assertIn("`_arm64.deb`", release_docs)

    def test_macos_release_suffixes_stay_documented_for_the_website(self):
        """The resolver contract must change alongside either macOS filename suffix."""
        root = Path(__file__).resolve().parents[2]
        rebuild_script = (root / "ui/scripts/rebuild_macos_dmg.sh").read_text()
        release_docs = (root / "ui/RELEASING.md").read_text()

        self.assertIn('DMG_NAME="$(', rebuild_script)
        self.assertIn('"${CONTRACTS_SCRIPT}" macos-dmg-name', rebuild_script)
        self.assertIn("`-x64.dmg`", release_docs)
        self.assertIn("`-arm64.dmg`", release_docs)

    def test_windows_submission_archives_are_not_customer_downloads(self):
        """Submission-only Windows archives must never become website installers."""
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github/workflows/desktop-direct-builds.yml").read_text()
        release_docs = (root / "ui/RELEASING.md").read_text()

        self.assertIn("DeployDash_*_${{ matrix.arch }}.msixupload", workflow)
        self.assertIn("website must never offer", release_docs)

    def test_windows_release_assets_reject_unknown_architectures(self):
        """An unknown architecture must not create an unresolvable release filename."""
        with self.assertRaisesRegex(
            ReleaseContractError,
            "Windows Store architecture must be x64 or arm64",
        ):
            windows_store_artifact_names("1.2.3.0", arch="riscv64")

    def test_tag_release_attaches_one_consolidated_checksum_manifest(self):
        """One checksum owner prevents parallel jobs from clobbering partial manifests."""
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github/workflows/desktop-direct-builds.yml").read_text()

        self.assertIn("release-checksums:", workflow)
        self.assertIn("name: Generate consolidated SHA256SUMS", workflow)
        self.assertIn('sha256sum "${assets[@]}" > SHA256SUMS', workflow)
        self.assertIn(
            'gh release upload "${GITHUB_REF_NAME}" SHA256SUMS --clobber',
            workflow,
        )

    def test_store_cert_watch_skips_cleanly_until_credentials_are_configured(self):
        """An optional read-only monitor must not make main permanently red before setup."""
        root = Path(__file__).resolve().parents[2]
        watch = (root / ".github/workflows/store-cert-watch.yml").read_text()
        submit = (root / ".github/workflows/store-submit.yml").read_text()

        self.assertIn("name: Check Store credential availability", watch)
        self.assertIn("id: store_credentials", watch)
        self.assertIn('echo "configured=false" >> "${GITHUB_OUTPUT}"', watch)
        self.assertIn("Store certification watch skipped", watch)
        self.assertEqual(
            watch.count("if: steps.store_credentials.outputs.configured == 'true'"),
            4,
        )
        # Submission fails closed in the shared Store CLI wrapper, which both
        # the pipeline and the manual retry workflow call.
        store_cli = (root / "ui/scripts/lib/store_cli.sh").read_text()
        self.assertIn("Store submission secrets are not configured.", store_cli)
        self.assertIn("return 1", store_cli)
        self.assertIn("bash ui/scripts/store_submit_release.sh", submit)

    def test_store_submit_downloads_draft_releases_by_list_not_tag_lookup(self):
        """Get-by-tag 404s for drafts; list + asset API is the durable download path."""
        root = Path(__file__).resolve().parents[2]
        script = (root / "ui/scripts/store_submit_release.sh").read_text()
        release_workflow = (root / ".github/workflows/release.yml").read_text()
        retry_workflow = (root / ".github/workflows/store-submit.yml").read_text()

        self.assertNotIn('gh release download "${tag}"', script)
        self.assertIn("repos/${REPO}/releases?per_page=100", script)
        self.assertIn("Accept: application/octet-stream", script)
        self.assertIn("repos/${REPO}/releases/assets/", script)
        # Marker edit on the draft needs write; read-only cannot list/edit drafts
        # reliably under GITHUB_TOKEN for this job.
        self.assertRegex(
            release_workflow,
            r"store-submit:[\s\S]*?permissions:\n(?:\s+#[^\n]*\n)*\s+contents: write",
        )
        self.assertRegex(
            retry_workflow,
            re.compile(
                r"^permissions:\n(?:\s+#[^\n]*\n)*\s+contents: write",
                re.MULTILINE,
            ),
        )

    def test_store_submit_treats_msstore_package_publish_as_commit(self):
        """Current msstore publish commits; a second commit step races Certification."""
        root = Path(__file__).resolve().parents[2]
        script = (root / "ui/scripts/store_submit_release.sh").read_text()
        store_cli = (root / "ui/scripts/lib/store_cli.sh").read_text()

        self.assertIn('msstore publish "${package}"', script)
        self.assertNotIn("msstore submission publish", script)
        self.assertNotIn("msstore submission poll", script)
        self.assertIn("msstore_submission_json_from_text", script)
        self.assertIn('-f tag_name="${tag}"', script)
        self.assertIn("msstore_capture", script)
        # Capture helpers live once in store_cli.sh (one owner).
        self.assertIn("msstore_capture()", store_cli)
        self.assertIn("msstore_submission_json_from_text()", store_cli)

    def test_store_publish_watch_avoids_msstore_pipefail_and_draft_get_by_tag(self):
        """Watcher must not die on sed EPIPE or draft get-by-tag 404s."""
        root = Path(__file__).resolve().parents[2]
        script = (root / "ui/scripts/store_publish_watch.sh").read_text()

        self.assertNotIn("store_cli_session msstore submission get", script)
        self.assertNotIn("grep -m1 '^{'", script)
        self.assertIn("msstore_capture", script)
        self.assertIn("msstore_submission_json_from_text", script)
        self.assertNotIn('gh release view "${tag}"', script)
        self.assertIn("repos/${REPO}/releases/${release_id}", script)
        self.assertIn("-F draft=false", script)

    def test_release_runs_hosted_windows_slim_before_qa_handoff(self):
        """The private Windows suite runs on hosted runners in the push run."""
        root = Path(__file__).resolve().parents[2]
        release = (root / ".github/workflows/release.yml").read_text()

        self.assertIn("slim-windows:", release)
        self.assertIn("uses: ./.github/workflows/qa-public-windows-slim.yml", release)
        self.assertIn("app-ref: ${{ github.ref_name }}", release)
        self.assertIn("base-version: ${{ needs.version.outputs.base_version }}", release)
        self.assertIn("candidate-version: ${{ needs.version.outputs.build_name }}", release)

    def test_qa_handoff_waits_for_slim_and_skips_qa_windows_leg(self):
        """Handoff fires only after slim passes and tells QA Windows is covered."""
        root = Path(__file__).resolve().parents[2]
        release = (root / ".github/workflows/release.yml").read_text()

        self.assertRegex(
            release,
            r"needs:\s*\[\s*version,\s*build-direct,\s*build-snap,\s*slim-windows,\s*slim-macos\s*\]",
        )
        self.assertIn("needs.slim-windows.result == 'success'", release)
        self.assertIn("client_payload[skip_windows]", release)

    def test_qa_handoff_waits_for_macos_slim_and_skips_qa_macos_leg(self):
        """Handoff fires only after the macOS slim passes and tells QA macOS is covered."""
        root = Path(__file__).resolve().parents[2]
        release = (root / ".github/workflows/release.yml").read_text()

        self.assertIn("needs.slim-macos.result == 'success'", release)
        self.assertIn("client_payload[skip_macos]", release)
        self.assertIn("macOS slim QA (hosted)", release)

    def test_publish_refuses_without_hosted_slim_success(self):
        """validate-qa re-checks the push run's slim conclusion (D7)."""
        root = Path(__file__).resolve().parents[2]
        release = (root / ".github/workflows/release.yml").read_text()

        self.assertIn("Require hosted Windows slim success for this SHA", release)
        self.assertIn('select(.name == "Windows slim QA (hosted)")', release)
        self.assertIn("Require hosted macOS slim success for this SHA", release)
        self.assertIn('select(.name == "macOS slim QA (hosted)")', release)
        self.assertIn("refusing to publish", release)


if __name__ == "__main__":
    unittest.main()
