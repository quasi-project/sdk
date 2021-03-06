// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of vmservice_io;

_sanitizeWindowsPath(path) {
  // For Windows we need to massage the paths a bit according to
  // http://blogs.msdn.com/b/ie/archive/2006/12/06/file-uris-in-windows.aspx
  //
  // Convert
  // C:\one\two\three
  // to
  // /C:/one/two/three

  if (_isWindows == false) {
    // Do nothing when not running Windows.
    return path;
  }

  var fixedPath = "${path.replaceAll('\\', '/')}";

  if ((path.length > 2) && (path[1] == ':')) {
    // Path begins with a drive letter.
    return '/$fixedPath';
  }

  return fixedPath;
}

_trimWindowsPath(path) {
  // Convert /X:/ to X:/.
  if (_isWindows == false) {
    // Do nothing when not running Windows.
    return path;
  }
  if (!path.startsWith('/') || (path.length < 3)) {
    return path;
  }
  // Match '/?:'.
  if ((path[0] == '/') && (path[2] == ':')) {
    // Remove leading '/'.
    return path.substring(1);
  }
  return path;
}

// Ensure we have a trailing slash character.
_enforceTrailingSlash(uri) {
  if (!uri.endsWith('/')) {
    return '$uri/';
  }
  return uri;
}

// State associated with the isolate that is used for loading.
class IsolateLoaderState extends IsolateEmbedderData {
  IsolateLoaderState(this.isolateId);

  final int isolateId;

  SendPort sp;

  void init(String packageRootFlag,
            String packagesConfigFlag,
            String workingDirectory,
            String rootScript) {
    // _workingDirectory must be set first.
    _workingDirectory = new Uri.directory(workingDirectory);
    if (rootScript != null) {
      _rootScript = Uri.parse(rootScript);
    }
    // If the --package-root flag was passed.
    if (packageRootFlag != null) {
      _setPackageRoot(packageRootFlag);
    }
    // If the --packages flag was passed.
    if (packagesConfigFlag != null) {
      _setPackagesConfig(packagesConfigFlag);
    }
  }

  void cleanup() {
    if (_packagesPort != null) {
      _packagesPort.close();
      _packagesPort = null;
    }
  }

  // The working directory when the embedder started.
  Uri _workingDirectory;

  // The root script's uri.
  Uri _rootScript;

  bool _traceLoading = false;

  // Packages are either resolved looking up in a map or resolved from within a
  // package root.
  bool get _packagesReady => (_packageRoot != null) ||
                             (_packageMap != null) ||
                             (_packageError != null);

  // Error string set if there was an error resolving package configuration.
  // For example not finding a .packages file or packages/ directory, malformed
  // .packages file or any other related error.
  String _packageError = null;

  // The directory to look in to resolve "package:" scheme URIs. By default it
  // is the 'packages' directory right next to the script.
  Uri _packageRoot = null;

  // The map describing how certain package names are mapped to Uris.
  Uri _packageConfig = null;
  Map<String, Uri> _packageMap = null;

  _setPackageRoot(String packageRoot) {
    packageRoot = _sanitizeWindowsPath(packageRoot);
    if (packageRoot.startsWith('file:') ||
        packageRoot.startsWith('http:') ||
        packageRoot.startsWith('https:')) {
      packageRoot = _enforceTrailingSlash(packageRoot);
      _packageRoot = _workingDirectory.resolve(packageRoot);
    } else {
      packageRoot = _sanitizeWindowsPath(packageRoot);
      packageRoot = _trimWindowsPath(packageRoot);
      _packageRoot =
          _workingDirectory.resolveUri(new Uri.directory(packageRoot));
    }
  }

  _setPackagesConfig(String packagesParam) {
    var packagesName = _sanitizeWindowsPath(packagesParam);
    var packagesUri = Uri.parse(packagesName);
    if (packagesUri.scheme == '') {
      // Script does not have a scheme, assume that it is a path,
      // resolve it against the working directory.
      packagesUri = _workingDirectory.resolveUri(packagesUri);
    }
    _requestPackagesMap(packagesUri);
    _pendingPackageLoads.add(() {
      // Dummy action.
    });
  }

  // Handling of access to the package root or package map from user code.
  _triggerPackageResolution(action) {
    if (_packagesReady) {
      // Packages are ready. Execute the action now.
      action();
    } else {
      if (_pendingPackageLoads.isEmpty) {
        // Package resolution has not been setup yet, and this is the first
        // request for package resolution & loading.
        _requestPackagesMap();
      }
      // Register the action for when the package resolution is ready.
      _pendingPackageLoads.add(action);
    }
  }

  // A list of callbacks which should be invoked after the package map has been
  // loaded.
  List<Function> _pendingPackageLoads = [];

  // Given a uri with a 'package' scheme, return a Uri that is prefixed with
  // the package root or resolved relative to the package configuration.
  Uri _resolvePackageUri(Uri uri) {
    assert(uri.scheme == "package");
    assert(_packagesReady);

    if (uri.host.isNotEmpty) {
      var path = '${uri.host}${uri.path}';
      var right = 'package:$path';
      var wrong = 'package://$path';

      throw "URIs using the 'package:' scheme should look like "
            "'$right', not '$wrong'.";
    }

    var packageNameEnd = uri.path.indexOf('/');
    if (packageNameEnd == 0) {
      // Package URIs must have a non-empty package name (not start with "/").
      throw "URIS using the 'package:' scheme should look like "
            "'package:packageName${uri.path}', not 'package:${uri.path}'";
    }
    if (_traceLoading) {
      _log('Resolving package with uri path: ${uri.path}');
    }
    var resolvedUri;
    if (_packageError != null) {
      if (_traceLoading) {
        _log("Resolving package with pending resolution error: $_packageError");
      }
      throw _packageError;
    } else if (_packageRoot != null) {
      resolvedUri = _packageRoot.resolve(uri.path);
    } else {
      if (packageNameEnd < 0) {
        // Package URIs must have a path after the package name, even if it's
        // just "/".
        throw "URIS using the 'package:' scheme should look like "
              "'package:${uri.path}/', not 'package:${uri.path}'";
      }
      var packageName = uri.path.substring(0, packageNameEnd);
      var mapping = _packageMap[packageName];
      if (_traceLoading) {
        _log("Mapped '$packageName' package to '$mapping'");
      }
      if (mapping == null) {
        throw "No mapping for '$packageName' package when resolving '$uri'.";
      }
      var path;
      assert(uri.path.length > packageName.length);
      path = uri.path.substring(packageName.length + 1);
      if (_traceLoading) {
        _log("Path to be resolved in package: $path");
      }
      resolvedUri = mapping.resolve(path);
    }
    if (_traceLoading) {
      _log("Resolved '$uri' to '$resolvedUri'.");
    }
    return resolvedUri;
  }

  RawReceivePort _packagesPort;

  void _requestPackagesMap([Uri packageConfig]) {
    assert(_packagesPort == null);
    assert(_rootScript != null);
    // Create a port to receive the packages map on.
    _packagesPort = new RawReceivePort(_handlePackagesReply);
    var sp = _packagesPort.sendPort;

    if (packageConfig != null) {
      // Explicitly specified .packages path.
      _handlePackagesRequest(sp,
                             _traceLoading,
                             -2,
                             packageConfig);
    } else {
      // Search for .packages or packages/ starting at the root script.
      _handlePackagesRequest(sp,
                             _traceLoading,
                             -1,
                             _rootScript);
    }

    if (_traceLoading) {
      _log("Requested packages map for '$_rootScript'.");
    }
  }

  void _handlePackagesReply(msg) {
    assert(_packagesPort != null);
    // Make sure to close the _packagePort before any other action.
    _packagesPort.close();
    _packagesPort = null;

    if (_traceLoading) {
      _log("Got packages reply: $msg");
    }
    if (msg is String) {
      if (_traceLoading) {
        _log("Got failure response on package port: '$msg'");
      }
      // Remember the error message.
      _packageError = msg;
    } else if (msg is List) {
      if (msg.length == 1) {
        if (_traceLoading) {
          _log("Received package root: '${msg[0]}'");
        }
        _packageRoot = Uri.parse(msg[0]);
      } else {
        // First entry contains the location of the loaded .packages file.
        assert((msg.length % 2) == 0);
        assert(msg.length >= 2);
        assert(msg[1] == null);
        _packageConfig = Uri.parse(msg[0]);
        _packageMap = new Map<String, Uri>();
        for (var i = 2; i < msg.length; i+=2) {
          // TODO(iposva): Complain about duplicate entries.
          _packageMap[msg[i]] = Uri.parse(msg[i+1]);
        }
        if (_traceLoading) {
          _log("Setup package map: $_packageMap");
        }
      }
    } else {
      _packageError = "Bad type of packages reply: ${msg.runtimeType}";
      if (_traceLoading) {
        _log(_packageError);
      }
    }

    // Resolve all pending package loads now that we know how to resolve them.
    while (_pendingPackageLoads.length > 0) {
      // Order does not matter as we queue all of the requests up right now.
      var req = _pendingPackageLoads.removeLast();
      // Call the registered closure, to handle the delayed action.
      req();
    }
    // Reset the pending package loads to empty. So that we eventually can
    // finish loading.
    _pendingPackageLoads = [];
  }

}

_log(msg) {
  print("% $msg");
}

var _httpClient;

// Send a response to the requesting isolate.
void _sendResourceResponse(SendPort sp,
                           int tag,
                           Uri uri,
                           String libraryUrl,
                           dynamic data) {
  assert((data is List<int>) || (data is String));
  var msg = new List(4);
  if (data is String) {
    // We encountered an error, flip the sign of the tag to indicate that.
    tag = -tag;
    if (libraryUrl == null) {
      data = 'Could not load "$uri": $data';
    } else {
      data = 'Could not import "$uri" from "$libraryUrl": $data';
    }
  }
  msg[0] = tag;
  msg[1] = uri.toString();
  msg[2] = libraryUrl;
  msg[3] = data;
  sp.send(msg);
}

void _loadHttp(SendPort sp,
               int tag,
               Uri uri,
               Uri resolvedUri,
               String libraryUrl) {
  if (_httpClient == null) {
    _httpClient = new HttpClient()..maxConnectionsPerHost = 6;
  }
  _httpClient.getUrl(resolvedUri)
    .then((HttpClientRequest request) => request.close())
    .then((HttpClientResponse response) {
      var builder = new BytesBuilder(copy: false);
      response.listen(
          builder.add,
          onDone: () {
            if (response.statusCode != 200) {
              var msg = "Failure getting $resolvedUri:\n"
                        "  ${response.statusCode} ${response.reasonPhrase}";
              _sendResourceResponse(sp, tag, uri, libraryUrl, msg);
            } else {
              _sendResourceResponse(sp, tag, uri, libraryUrl,
                                    builder.takeBytes());
            }
          },
          onError: (e) {
            _sendResourceResponse(sp, tag, uri, libraryUrl, e.toString());
          });
    })
    .catchError((e) {
      _sendResourceResponse(sp, tag, uri, libraryUrl, e.toString());
    });
  // It's just here to push an event on the event loop so that we invoke the
  // scheduled microtasks.
  Timer.run(() {});
}

void _loadFile(SendPort sp,
               int tag,
               Uri uri,
               Uri resolvedUri,
               String libraryUrl) {
  var path = resolvedUri.toFilePath();
  var sourceFile = new File(path);
  sourceFile.readAsBytes().then((data) {
    _sendResourceResponse(sp, tag, uri, libraryUrl, data);
  },
  onError: (e) {
    _sendResourceResponse(sp, tag, uri, libraryUrl, e.toString());
  });
}

void _loadDataUri(SendPort sp,
                  int tag,
                  Uri uri,
                  Uri resolvedUri,
                  String libraryUrl) {
  try {
    var mime = uri.data.mimeType;
    if ((mime != "application/dart") &&
        (mime != "text/plain")) {
      throw "MIME-type must be application/dart or text/plain: $mime given.";
    }
    var charset = uri.data.charset;
    if ((charset != "utf-8") &&
        (charset != "US-ASCII")) {
      // The C++ portion of the embedder assumes UTF-8.
      throw "Only utf-8 or US-ASCII encodings are supported: $charset given.";
    }
    _sendResourceResponse(sp, tag, uri, libraryUrl, uri.data.contentAsBytes());
  } catch (e) {
    _sendResourceResponse(sp, tag, uri, libraryUrl,
                          "Invalid data uri ($uri):\n  $e");
  }
}

// Loading a package URI needs to first map the package name to a loadable
// URI.
_loadPackage(IsolateLoaderState loaderState,
             SendPort sp,
             bool traceLoading,
             int tag,
             Uri uri,
             Uri resolvedUri,
             String libraryUrl) {
  if (loaderState._packagesReady) {
    var resolvedUri;
    try {
      resolvedUri = loaderState._resolvePackageUri(uri);
    } catch (e, s) {
      if (traceLoading) {
        _log("Exception ($e) when resolving package URI: $uri");
      }
      // Report error.
      _sendResourceResponse(sp,
                            tag,
                            uri,
                            libraryUrl,
                            e.toString());
      return;
    }
    // Recursively call with the new resolved uri.
    _handleResourceRequest(loaderState,
                           sp,
                           traceLoading,
                           tag,
                           uri,
                           resolvedUri,
                           libraryUrl);
  } else {
    if (loaderState._pendingPackageLoads.isEmpty) {
      // Package resolution has not been setup yet, and this is the first
      // request for package resolution & loading.
      loaderState._requestPackagesMap();
    }
    // Register the action of loading this package once the package resolution
    // is ready.
    loaderState._pendingPackageLoads.add(() {
      _handleResourceRequest(loaderState,
                             sp,
                             traceLoading,
                             tag,
                             uri,
                             uri,
                             libraryUrl);
    });
    if (traceLoading) {
      _log("Pending package load of '$uri': "
           "${loaderState._pendingPackageLoads.length} pending");
    }
  }
}

// TODO(johnmccutchan): This and most other top level functions in this file
// should be turned into methods on the IsolateLoaderState class.
_handleResourceRequest(IsolateLoaderState loaderState,
                       SendPort sp,
                       bool traceLoading,
                       int tag,
                       Uri uri,
                       Uri resolvedUri,
                       String libraryUrl) {
  if (resolvedUri.scheme == '' || resolvedUri.scheme == 'file') {
    _loadFile(sp, tag, uri, resolvedUri, libraryUrl);
  } else if ((resolvedUri.scheme == 'http') ||
             (resolvedUri.scheme == 'https')) {
    _loadHttp(sp, tag, uri, resolvedUri, libraryUrl);
  } else if ((resolvedUri.scheme == 'data')) {
    _loadDataUri(sp, tag, uri, resolvedUri, libraryUrl);
  } else if ((resolvedUri.scheme == 'package')) {
    _loadPackage(loaderState,
                 sp,
                 traceLoading,
                 tag,
                 uri,
                 resolvedUri,
                 libraryUrl);
  } else {
    _sendResourceResponse(sp, tag,
                          uri,
                          libraryUrl,
                          'Unknown scheme (${resolvedUri.scheme}) for '
                          '$resolvedUri');
  }
}

// Handling of packages requests. Finding and parsing of .packages file or
// packages/ directories.
const _LF    = 0x0A;
const _CR    = 0x0D;
const _SPACE = 0x20;
const _HASH  = 0x23;
const _DOT   = 0x2E;
const _COLON = 0x3A;
const _DEL   = 0x7F;

const _invalidPackageNameChars = const [
  // space  !      "      #      $      %      &      '
     true , false, true , true , false, true , false, false,
  // (      )      *      +      ,      -      .      /
     false, false, false, false, false, false, false, true ,
  // 0      1      2      3      4      5      6      7
     false, false, false, false, false, false, false, false,
  // 8      9      :      ;      <      =      >      ?
     false, false, true , false, true , false, true , true ,
  // @      A      B      C      D      E      F      G
     false, false, false, false, false, false, false, false,
  // H      I      J      K      L      M      N      O
     false, false, false, false, false, false, false, false,
  // P      Q      R      S      T      U      V      W
     false, false, false, false, false, false, false, false,
  // X      Y      Z      [      \      ]      ^      _
     false, false, false, true , true , true , true , false,
  // `      a      b      c      d      e      f      g
     true , false, false, false, false, false, false, false,
  // h      i      j      k      l      m      n      o
     false, false, false, false, false, false, false, false,
  // p      q      r      s      t      u      v      w
     false, false, false, false, false, false, false, false,
  // x      y      z      {      |      }      ~      DEL
     false, false, false, true , true , true , false, true
];

_parsePackagesFile(SendPort sp,
                   bool traceLoading,
                   Uri packagesFile,
                   List<int> data) {
  // The first entry contains the location of the identified .packages file
  // instead of a mapping.
  var result = [packagesFile.toString(), null];
  var index = 0;
  var len = data.length;
  while (index < len) {
    var start = index;
    var char = data[index];
    if ((char == _CR) || (char == _LF)) {
      // Skipping empty lines.
      index++;
      continue;
    }

    // Identify split within the line and end of the line.
    var separator = -1;
    var end = len;
    // Verifying validity of package name while scanning the line.
    var nonDot = false;
    var invalidPackageName = false;

    // Scan to the end of the line or data.
    while (index < len) {
      char = data[index++];
      // If we have not reached the separator yet, determine whether we are
      // scanning legal package name characters.
      if (separator == -1) {
        if ((char == _COLON)) {
          // The first colon on a line is the separator between package name and
          // related URI.
          separator = index - 1;
        } else {
          // Still scanning the package name part. Check for the validity of
          // the characters.
          nonDot = nonDot || (char != _DOT);
          invalidPackageName = invalidPackageName ||
                               (char < _SPACE) || (char > _DEL) ||
                               _invalidPackageNameChars[char - _SPACE];
        }
      }
      // Identify end of line.
      if ((char == _CR) || (char == _LF)) {
        end = index - 1;
        break;
      }
    }

    // No further handling needed for comment lines.
    if (data[start] == _HASH) {
      if (traceLoading) {
        _log("Skipping comment in $packagesFile:\n"
             "${new String.fromCharCodes(data, start, end)}");
      }
      continue;
    }

    // Check for a badly formatted line, starting with a ':'.
    if (separator == start) {
      var line = new String.fromCharCodes(data, start, end);
      if (traceLoading) {
        _log("Line starts with ':' in $packagesFile:\n"
             "$line");
      }
      sp.send("Missing package name in $packagesFile:\n"
              "$line");
      return;
    }

    // Ensure there is a separator on the line.
    if (separator == -1) {
      var line = new String.fromCharCodes(data, start, end);
      if (traceLoading) {
        _log("Line has no ':' in $packagesFile:\n"
              "$line");
      }
      sp.send("Missing ':' separator in $packagesFile:\n"
              "$line");
      return;
    }

    var packageName = new String.fromCharCodes(data, start, separator);

    // Check for valid package name.
    if (invalidPackageName || !nonDot) {
      var line = new String.fromCharCodes(data, start, end);
      if (traceLoading) {
        _log("Invalid package name $packageName in $packagesFile");
      }
      sp.send("Invalid package name '$packageName' in $packagesFile:\n"
              "$line");
      return;
    }

    if (traceLoading) {
      _log("packageName: $packageName");
    }
    var packageUri = new String.fromCharCodes(data, separator + 1, end);
    if (traceLoading) {
      _log("original packageUri: $packageUri");
    }
    // Ensure the package uri ends with a /.
    if (!packageUri.endsWith("/")) {
      packageUri = "$packageUri/";
    }
    packageUri = packagesFile.resolve(packageUri).toString();
    if (traceLoading) {
      _log("mapping: $packageName -> $packageUri");
    }
    result.add(packageName);
    result.add(packageUri);
  }

  if (traceLoading) {
    _log("Parsed packages file at $packagesFile. Sending:\n$result");
  }
  sp.send(result);
}

_loadPackagesFile(SendPort sp, bool traceLoading, Uri packagesFile) async {
  try {
    var data = await new File.fromUri(packagesFile).readAsBytes();
    if (traceLoading) {
      _log("Loaded packages file from $packagesFile:\n"
           "${new String.fromCharCodes(data)}");
    }
    _parsePackagesFile(sp, traceLoading, packagesFile, data);
  } catch (e, s) {
    if (traceLoading) {
      _log("Error loading packages: $e\n$s");
    }
    sp.send("Uncaught error ($e) loading packages file.");
  }
}

_findPackagesFile(SendPort sp, bool traceLoading, Uri base) async {
  try {
    // Walk up the directory hierarchy to check for the existence of
    // .packages files in parent directories and for the existense of a
    // packages/ directory on the first iteration.
    var dir = new File.fromUri(base).parent;
    var prev = null;
    // Keep searching until we reach the root.
    while ((prev == null) || (prev.path != dir.path)) {
      // Check for the existence of a .packages file and if it exists try to
      // load and parse it.
      var dirUri = dir.uri;
      var packagesFile = dirUri.resolve(".packages");
      if (traceLoading) {
        _log("Checking for $packagesFile file.");
      }
      var exists = await new File.fromUri(packagesFile).exists();
      if (traceLoading) {
        _log("$packagesFile exists: $exists");
      }
      if (exists) {
        _loadPackagesFile(sp, traceLoading, packagesFile);
        return;
      }
      // On the first loop try whether there is a packages/ directory instead.
      if (prev == null) {
        var packageRoot = dirUri.resolve("packages/");
        if (traceLoading) {
          _log("Checking for $packageRoot directory.");
        }
        exists = await new Directory.fromUri(packageRoot).exists();
        if (traceLoading) {
          _log("$packageRoot exists: $exists");
        }
        if (exists) {
          if (traceLoading) {
            _log("Found a package root at: $packageRoot");
          }
          sp.send([packageRoot.toString()]);
          return;
        }
      }
      // Move up one level.
      prev = dir;
      dir = dir.parent;
    }

    // No .packages file was found.
    if (traceLoading) {
      _log("Could not resolve a package location from $base");
    }
    sp.send("Could not resolve a package location for base at $base");
  } catch (e, s) {
    if (traceLoading) {
      _log("Error loading packages: $e\n$s");
    }
    sp.send("Uncaught error ($e) loading packages file.");
  }
}

Future<bool> _loadHttpPackagesFile(SendPort sp,
                                   bool traceLoading,
                                   Uri resource) async {
  try {
    if (_httpClient == null) {
      _httpClient = new HttpClient()..maxConnectionsPerHost = 6;
    }
    if (traceLoading) {
      _log("Fetching packages file from '$resource'.");
    }
    var req = await _httpClient.getUrl(resource);
    var rsp = await req.close();
    var builder = new BytesBuilder(copy: false);
    await for (var bytes in rsp) {
      builder.add(bytes);
    }
    if (rsp.statusCode != 200) {
      if (traceLoading) {
        _log("Got status ${rsp.statusCode} fetching '$resource'.");
      }
      return false;
    }
    var data = builder.takeBytes();
    if (traceLoading) {
      _log("Loaded packages file from '$resource':\n"
           "${new String.fromCharCodes(data)}");
    }
    _parsePackagesFile(sp, traceLoading, resource, data);
  } catch (e, s) {
    if (traceLoading) {
      _log("Error loading packages file from '$resource': $e\n$s");
    }
    sp.send("Uncaught error ($e) loading packages file from '$resource'.");
  }
  return false;
}

_loadPackagesData(sp, traceLoading, resource){
  try {
    var data = resource.data;
    var mime = data.mimeType;
    if (mime != "text/plain") {
      throw "MIME-type must be text/plain: $mime given.";
    }
    var charset = data.charset;
    if ((charset != "utf-8") &&
        (charset != "US-ASCII")) {
      // The C++ portion of the embedder assumes UTF-8.
      throw "Only utf-8 or US-ASCII encodings are supported: $charset given.";
    }
    _parsePackagesFile(sp, traceLoading, resource, data.contentAsBytes());
  } catch (e) {
    sp.send("Uncaught error ($e) loading packages data.");
  }
}

// This code used to exist in a second isolate and so it uses a SendPort to
// report it's return value. This could be refactored so that it returns it's
// value and the caller could wait on the future rather than a message on
// SendPort.
_handlePackagesRequest(SendPort sp,
                       bool traceLoading,
                       int tag,
                       Uri resource) async {
  try {
    if (tag == -1) {
      if (resource.scheme == '' || resource.scheme == 'file') {
        _findPackagesFile(sp, traceLoading, resource);
      } else if ((resource.scheme == 'http') || (resource.scheme == 'https')) {
        // Try to load the .packages file next to the resource.
        var packagesUri = resource.resolve(".packages");
        var exists = await _loadHttpPackagesFile(sp, traceLoading, packagesUri);
        if (!exists) {
          // If the loading of the .packages file failed for http/https based
          // scripts then setup the package root.
          var packageRoot = resource.resolve('packages/');
          sp.send([packageRoot.toString()]);
        }
      } else {
        sp.send("Unsupported scheme used to locate .packages file: "
                "'$resource'.");
      }
    } else if (tag == -2) {
      if (traceLoading) {
        _log("Handling load of packages map: '$resource'.");
      }
      if (resource.scheme == '' || resource.scheme == 'file') {
        var exists = await new File.fromUri(resource).exists();
        if (exists) {
          _loadPackagesFile(sp, traceLoading, resource);
        } else {
          sp.send("Packages file '$resource' not found.");
        }
      } else if ((resource.scheme == 'http') || (resource.scheme == 'https')) {
        var exists = await _loadHttpPackagesFile(sp, traceLoading, resource);
        if (!exists) {
          sp.send("Packages file '$resource' not found.");
        }
      } else if (resource.scheme == 'data') {
        _loadPackagesData(sp, traceLoading, resource);
      } else {
        sp.send("Unknown scheme (${resource.scheme}) for package file at "
                "'$resource'.");
      }
    } else {
      sp.send("Unknown packages request tag: $tag for '$resource'.");
    }
  } catch (e, s) {
    if (traceLoading) {
      _log("Error handling packages request: $e\n$s");
    }
    sp.send("Uncaught error ($e) handling packages request.");
  }
}

// Shutdown all active loaders by sending an error message.
void shutdownLoaders() {
  String message = 'Service shutdown';
  if (_httpClient != null) {
    _httpClient.close(force: true);
    _httpClient = null;
  }
  isolateEmbedderData.values.toList().forEach((IsolateLoaderState ils) {
    ils.cleanup();
    assert(ils.sp != null);
    _sendResourceResponse(ils.sp, 1, null, null, message);
  });
}

// See Dart_LibraryTag in dart_api.h
const _Dart_kCanonicalizeUrl = 0;      // Canonicalize the URL.
const _Dart_kScriptTag = 1;            // Load the root script.
const _Dart_kSourceTag = 2;            // Load a part source.
const _Dart_kImportTag = 3;            // Import a library.

// Extra requests. Keep these in sync between loader.dart and builtin.dart.
const _Dart_kInitLoader = 4;           // Initialize the loader.
const _Dart_kResourceLoad = 5;         // Resource class support.
const _Dart_kGetPackageRootUri = 6;    // Uri of the packages/ directory.
const _Dart_kGetPackageConfigUri = 7;  // Uri of the .packages file.
const _Dart_kResolvePackageUri = 8;    // Resolve a package: uri.

// External entry point for loader requests.
_processLoadRequest(request) {
  assert(request is List);
  assert(request.length > 4);

  // Should we trace loading?
  bool traceLoading = request[0];

  // This is the sending isolate's Dart_GetMainPortId().
  int isolateId = request[1];

  // The tag describing the operation.
  int tag = request[2];

  // The send port to send the response on.
  SendPort sp = request[3];

  // Grab the loader state for the requesting isolate.
  IsolateLoaderState loaderState = isolateEmbedderData[isolateId];

  // We are either about to initialize the loader, or, we already have.
  assert((tag == _Dart_kInitLoader) || (loaderState != null));

  // Handle the request specified in the tag.
  switch (tag) {
    case _Dart_kScriptTag: {
      Uri uri = Uri.parse(request[4]);
      // Remember the root script.
      loaderState._rootScript = uri;
      _handleResourceRequest(loaderState,
                             sp,
                             traceLoading,
                             tag,
                             uri,
                             uri,
                             null);
    }
    break;
    case _Dart_kSourceTag:
    case _Dart_kImportTag: {
      // The url of the file being loaded.
      var uri = Uri.parse(request[4]);
      // The library that is importing/parting the file.
      String libraryUrl = request[5];
      _handleResourceRequest(loaderState,
                             sp,
                             traceLoading,
                             tag,
                             uri,
                             uri,
                             libraryUrl);
    }
    break;
    case _Dart_kInitLoader: {
      String packageRoot = request[4];
      String packagesFile = request[5];
      String workingDirectory = request[6];
      String rootScript = request[7];
      if (loaderState == null) {
        loaderState = new IsolateLoaderState(isolateId);
        isolateEmbedderData[isolateId] = loaderState;
        loaderState.init(packageRoot,
                         packagesFile,
                         workingDirectory,
                         rootScript);
      }
      loaderState.sp = sp;
      assert(isolateEmbedderData[isolateId] == loaderState);
    }
    break;
    case _Dart_kResourceLoad: {
      Uri uri = Uri.parse(request[4]);
      _handleResourceRequest(loaderState,
                             sp,
                             traceLoading,
                             tag,
                             uri,
                             uri,
                             null);
    }
    break;
    case _Dart_kGetPackageRootUri:
      loaderState._triggerPackageResolution(() {
        // Respond with the package root (if any) after package resolution.
        sp.send(loaderState._packageRoot);
      });
    break;
    case _Dart_kGetPackageConfigUri:
      loaderState._triggerPackageResolution(() {
        // Respond with the packages config (if any) after package resolution.
        sp.send(loaderState._packageConfig);
      });
    break;
    case _Dart_kResolvePackageUri:
      Uri uri = Uri.parse(request[4]);
      loaderState._triggerPackageResolution(() {
        // Respond with the resolved package uri after package resolution.
        Uri resolvedUri;
        try {
          resolvedUri = loaderState._resolvePackageUri(uri);
        } catch (e, s) {
          if (traceLoading) {
            _log("Exception ($e) when resolving package URI: $uri");
          }
          resolvedUri = null;
        }
        sp.send(resolvedUri);
      });
    break;
    default:
      _log('Unknown loader request tag=$tag from $isolateId');
  }
}
