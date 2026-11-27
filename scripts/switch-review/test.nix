# switch-review --dirs on two fake source trees (built by checks.scripts).
{ pkgs, switch-review }:
pkgs.runCommand "switch-review-test" { nativeBuildInputs = [ switch-review ]; } ''
  mkdir -p old/hosts/_shared/users new/hosts/_shared/users old/docs new/docs old/home new/home
  printf 'users.users.a = { };\n' > old/hosts/_shared/users/a.nix
  printf 'users.users.a = { };\nsecurity-path-marker = 1;\n' > new/hosts/_shared/users/a.nix
  printf 'x = 1;\n' > old/home/b.nix
  printf 'x = 1;\nextraGroups = [ "wheel" ];\nplain-keyword-file-marker = 2;\n' > new/home/b.nix
  mkdir -p old/keys new/keys
  printf 'a\0b' > old/keys/k
  printf 'a\0c' > new/keys/k
  printf 'old text\n' > old/docs/c.md
  printf 'unrelated-change-marker\n' > new/docs/c.md

  switch-review --dirs old new > out
  cat out
  fail() { echo "FAIL: $1"; exit 1; }
  # a security path shows in full, even lines without a keyword
  grep -q '^+security-path-marker = 1;' out || fail "security path not in full"
  # a changed binary file is named, not an abort
  grep -q 'Binary files a/keys/k and b/keys/k differ' out || fail "binary security file"
  # a keyword line elsewhere shows with its file name; its neighbour does not
  grep -q 'home/b.nix: +extraGroups = \[ "wheel" \];' out || fail "keyword line missing"
  grep -q plain-keyword-file-marker out && fail "non-keyword line of b.nix shown"
  # an unrelated change only in the file list
  grep -q 'docs/c.md' out || fail "unrelated file not listed"
  grep -q unrelated-change-marker out && fail "unrelated change shown"
  touch $out
''
