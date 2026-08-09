# Homebrew formula template for scrubmac.
#
# Lives in the tap repo (aviral2552/homebrew-tap) as Formula/scrubmac.rb;
# this copy is the source of truth kept in-repo. After each release, update
# `url` and `sha256` (from the release's SHA256SUMS) and push to the tap.
# See RELEASING.md.
class Scrubmac < Formula
  desc "Update and clean your dev tools with one command"
  homepage "https://github.com/aviral2552/scrubmac"
  # The uploaded release asset — the exact file SHA256SUMS describes. Not the
  # auto-generated /archive/ tarball, whose bytes GitHub does not guarantee
  # stable (the Jan 2023 archive-checksum breakage).
  url "https://github.com/aviral2552/scrubmac/releases/download/v3.0.1/scrubmac-3.0.1.tar.gz"
  sha256 "REPLACE_WITH_RELEASE_SHA256"
  license "GPL-3.0-only"

  depends_on :macos

  def install
    libexec.install "bin", "lib", "cleaners", "VERSION"
    bin.install_symlink libexec/"bin/scrubmac"
    man1.install "man/scrubmac.1"
  end

  def caveats
    <<~EOS
      Heavy pruners (docker, xcode) start disabled. Opt in with the wizard
      (`scrubmac configure`) or `scrubmac enable docker`.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/scrubmac version")
  end
end
