* `dart:io`
  * Added two new file modes, `WRITE_ONLY` and `WRITE_ONLY_APPEND` for
    opening a file write only.
    [eaeecf2](https://github.com/dart-lang/sdk/commit/eaeecf2ed13ba6c7fbfd653c3c592974a7120960)
  * Change stdout/stderr to binary mode on Windows.
    [4205b29](https://github.com/dart-lang/sdk/commit/4205b2997e01f2cea8e2f44c6f46ed6259ab7277)

### Tool changes

* Pub

  * Pub will now generate a ".packages" file in addition to the "packages"
    directory when running `pub get` or similar operations, per the
    [package spec proposal][]. Pub now has a `--no-package-symlinks` flag that
    will stop "packages" directories from being generated at all.

  * When `pub publish` finds a violation, it will emit a non-zero exit code.

  * `pub run` starts up faster for executables that don't import transformed
    code.

  * An issue where HTTP requests were sometimes made even though `--offline` was
    passed to `pub get` or `pub upgrade` has been fixed.

  * A bug with `--offline` that caused an unhelpful error message has been
    fixed.

  * A crashing bug involving transformers that only apply to non-public code has
    been fixed.

[package spec proposal]: https://github.com/lrhn/dep-pkgspec

## 1.11.1

### Tool changes

* Pub will always load Dart SDK assets from the SDK whose `pub` executable was
  run, even if a `DART_SDK` environment variable is set.

    [r45198](https://github.com/dart-lang/sdk/commit/5a79c03)
  [r45003](https://github.com/dart-lang/sdk/commit/8b8223d),
  [r45153](https://github.com/dart-lang/sdk/commit/8a5d049),
  [r45189](https://github.com/dart-lang/sdk/commit/3c39ad2)