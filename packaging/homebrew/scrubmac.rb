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
  url "https://github.com/aviral2552/scrubmac/releases/download/v3.1.0/scrubmac-3.1.0.tar.gz"
  sha256 "REPLACE_WITH_RELEASE_SHA256"
  license "GPL-3.0-only"

  depends_on :macos

  def install
    libexec.install "bin", "lib", "cleaners", "VERSION"
    bin.install_symlink libexec/"bin/scrubmac"
    man1.install "man/scrubmac.1"
    bash_completion.install "completions/scrubmac.bash" => "scrubmac"
    zsh_completion.install "completions/_scrubmac"
    fish_completion.install "completions/scrubmac.fish"
  end

  def caveats
    <<~EOS
      Opt-in cleaners (docker, xcode, go, rubygems) start disabled: enable them
      with the wizard (`scrubmac configure`) or `scrubmac enable docker`.
      Run it on a schedule with `scrubmac schedule weekly`; remove that with
      `scrubmac schedule off` before uninstalling.
    EOS
  end

  test do
    ENV["HOME"] = testpath
    assert_match version.to_s, shell_output("#{bin}/scrubmac version")
    assert_match "homebrew", shell_output("#{bin}/scrubmac list --names")
    # A dry run changes nothing. With only the system PATH, the cleaners
    # whose tools live elsewhere skip, and the summary counts them.
    ENV["PATH"] = "/usr/bin:/bin"
    assert_match(/\d+ ok, \d+ skipped, 0 failed/, shell_output("#{bin}/scrubmac --dry-run --quiet"))
  end
end
