# Homebrew formula template for mxup.
#
# Copy this file into your Homebrew tap repo (e.g. Recognized/homebrew-mxup)
# as Formula/mxup.rb. The release workflow's "homebrew" job will keep `url`
# and `sha256` in sync on every tag push once HOMEBREW_TAP / HOMEBREW_TAP_TOKEN
# are configured in the main repo's settings.
#
# Users then install with:
#   brew install Recognized/mxup/mxup
class Mxup < Formula
  desc "Declarative tmux session manager with reconciliation"
  homepage "https://github.com/Recognized/mxup"
  url "https://github.com/Recognized/mxup/archive/refs/tags/v0.2.0.tar.gz"
  sha256 "REPLACE_WITH_SHA256_OF_TARBALL"
  license "MIT"
  head "https://github.com/Recognized/mxup.git", branch: "main"

  depends_on "tmux"
  uses_from_macos "ruby"

  def install
    libexec.install "lib", "bin", "README.md", "LICENSE"
    (bin/"mxup").write <<~SH
      #!/bin/bash
      exec "#{Formula["ruby"].opt_bin}/ruby" -I "#{libexec}/lib" "#{libexec}/bin/mxup" "$@"
    SH
    (bin/"mxup").chmod 0755
  end

  test do
    assert_match "mxup #{version}", shell_output("#{bin}/mxup --version")
  end
end
