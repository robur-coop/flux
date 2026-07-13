  $ cat >data.log<<EOF
  > [debug] foo
  > [error] bar
  > [debug] bar
  > EOF
  $ ./error.exe data.log
  $ cat error.log
  [error] bar
  $ ocaml -stdin doc <<EOF
  > #use "mkdir_p.ml";;
  > let () = mkdir_p Sys.argv.(1) 0o755
  > EOF
  $ cat >doc/foo.txt<<EOF
  > FOO
  > EOF
  > cat >doc/bar.txt<<EOF
  > BAR
  > EOF
  $ ./zip.exe doc/foo.txt doc/bar.txt > archive.zip
  $ ./unzip.exe -o out archive.zip
  $ cat out/doc/foo.txt
  FOO
  $ cat out/doc/bar.txt
  BAR
