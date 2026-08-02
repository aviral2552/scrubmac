# Homebrew formula template for cleanmymac.
#
# Lives in the tap repo (aviral2552/homebrew-tap) as Formula/cleanmymac.rb;
# this copy is the source of truth kept in-repo. After each release, update
# `url` and `sha256` (from the release's SHA256SUMS) and push to the tap.
# See RELEASING.md.
class Cleanmymac < Formula
  desc "Update and clean your dev tools with one command"
  homepage "https://github.com/aviral2552/cleanmymac"
  # The uploaded release asset — the exact file SHA256SUMS describes. Not the
  # auto-generated /archive/ tarball, whose bytes GitHub does not guarantee
  # stable (the Jan 2023 archive-checksum breakage).
  url "https://github.com/aviral2552/cleanmymac/releases/download/v2.0.1/cleanmymac-2.0.1.tar.gz"
  sha256 "REPLACE_WITH_RELEASE_SHA256"
  license "GPL-3.0-only"

  depends_on :macos

  def install
    libexec.install "bin", "lib", "cleaners", "VERSION"
    bin.install_symlink libexec/"bin/cleanmymac"
    man1.install "man/cleanmymac.1"
  end

  def caveats
    <<~EOS
      Heavy pruners (docker, xcode) start disabled. Opt in with the wizard
      (`cleanmymac configure`) or `cleanmymac enable docker`.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/cleanmymac version")
  end
end
