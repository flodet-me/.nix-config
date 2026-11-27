# switch-review --dirs on two fake source trees (built by checks.scripts).
{ pkgs, switch-review }:
pkgs.runCommand "switch-review-test" { nativeBuildInputs = [ switch-review ]; } ''
  mkdir -p old/docs new/docs old/home new/home old/d
  # code anywhere: full diff
  printf 'x = 1;\n' > old/home/b.nix
  printf 'x = 1;\nhome-change-marker = 2;\n' > new/home/b.nix
  # docs/: name only
  printf 'old text\n' > old/docs/c.md
  printf 'docs-change-marker\n' > new/docs/c.md
  # odd file names
  printf 'space-marker\n' > 'new/home/with space.nix'
  printf 'newline-marker\n' > new/home/$'new\nline.nix'
  printf 'x\n' > new/home/$'cr\rname.nix'
  printf 'x\n' > new/home/$'esc\033name.nix'
  # non-regular files and type changes
  ln -s /etc/passwd new/home/link.nix
  ln -s same old/home/same-link
  ln -s same new/home/same-link
  printf 'inner-marker\n' > old/d/inner
  printf 'replacement-marker\n' > new/d
  # NUL, CR and ESC in content
  printf 'x\n' > old/home/bytes.nix
  printf 'x\0nul-marker\ncr-marker\r\n\033[31mesc-marker\n' > new/home/bytes.nix

  switch-review --dirs old new > out
  cat out
  fail() { echo "FAIL: $1"; exit 1; }
  has() { grep -qF -- "$1" out || fail "missing: $1"; }
  has '+home-change-marker = 2;'
  has 'M docs/c.md'
  grep -q docs-change-marker out && fail "docs content shown"
  has 'A home/with space.nix'
  has '+space-marker'
  has 'A home/new\nline.nix'
  has '+newline-marker'
  has 'home/link.nix: none -> symlink to /etc/passwd'
  has 'd: directory -> regular file'
  grep -q same-link out && fail "unchanged symlink listed"
  has '+replacement-marker'
  has '-inner-marker'
  has '+x^@nul-marker'
  has '+cr-marker^M'
  has '+^[[31mesc-marker'
  has 'cr^Mname.nix'
  has 'esc^[name.nix'
  grep -q $'[\r\033]' out && fail "raw CR or ESC in the output"
  touch $out
''
