#library("RedisClient");
#import("dart:io");
#import("Mixin.dart");

interface RedisConnection default _RedisConnection {
  RedisConnection([String connStr]);

  String password;
  String hostName;
  int port;
  int db;
  Map get stats();

  void parse([String connStr]);

  Future select(int selectDb);
  Future<String> sendExpectCode(List<List> cmdWithArgs);
  Future<Object> sendExpectSuccess(List<List> cmdWithArgs);
  Future<int> sendExpectInt(List<List> cmdWithArgs);
  Future<bool> sendExpectIntSuccess(List<List> cmdWithArgs);
  Future<List<int>> sendExpectData(List<List> cmdWithArgs);
  Future<List<List<int>>> sendExpectMultiData(List<List> cmdWithArgs);
  Future<String> sendExpectString(List<List> cmdWithArgs);
  Future<double> sendExpectDouble(List<List> cmdWithArgs);

  void close();
}

interface LogLevel {
  static final int None = 0;
  static final int Error = 1;
  static final int Warn = 2;
  static final int Info = 3;
  static final int Debug = 4;
  static final int All = 5;
}

interface Pipeline {
  completeVoidQueuedCommand(Function expectFn);
  completeIntQueuedCommand(Function expectFn);
  completeBytesQueuedCommand(Function expectFn);
  completeMultiBytesQueuedCommand(Function expectFn);
  completeStringQueuedCommand(Function expectFn);
}

class ExpectRead {
  Completer task;
  Function reader;
  List<int> buffer;
  SocketBuffer _socketBuffer;

  ExpectRead(Completer this.task, bool this.reader(InputStream stream, Completer task));

  bool execute(SocketWrapper wrapper){
    if (_socketBuffer == null)
      _socketBuffer = new SocketBuffer(wrapper);
    else
      _socketBuffer.rewind();

    reader(_socketBuffer, task);

    return task.future.isComplete;
  }
}

class _RedisConnection implements RedisConnection {
  Socket _socket;
  SocketInputStream _inStream;
  SocketWrapper _wrapper;

  //Valid usages:
  //pass@host:port/db
  //pass@host:port
  //pass@host
  //host
  //null => localhost:6379/0
  String password;
  String hostName = "localhost";
  int port = 6379;
  int db = 0;
  bool connected;
  List endData;
  Queue<List> readChunks;
  int logLevel = LogLevel.Error;

  Int8List cmdBuffer;
  int cmdBufferIndex = 0;
  static final int breathingSpace = 32 * 1024; //To Reduce Reallocations
  Pipeline pipeline;

  Queue<ExpectRead> pendingReads;

  //stats
  int totalBuffersWrites = 0;
  int totalBufferFlushes = 0;
  int totalBufferResizes = 0;
  int totalBytesWritten = 0;

  Map get stats() => $(_wrapper.stats).addAll({
    'bufferWrites':totalBuffersWrites,
    'flushes':totalBufferFlushes,
    'bytesWritten': totalBytesWritten,
    'bufferResizes': totalBufferResizes,
  });

  _RedisConnection([String connStr])
    : cmdBuffer = new Int8List(32 * 1024),
      pendingReads = new Queue<ExpectRead>(),
      readChunks = new Queue<List>(),
      endData = "\r\n".charCodes()
  {
    parse(connStr);
  }

  void parse([String connStr]){
    if (connStr == null) return;
    List<String> parts = $(connStr).splitOnLast("@");
    password = parts.length == 2 ? parts[0] : null;
    parts = $(parts.last()).splitOnLast(":");
    bool hasPort = parts.length == 2;
    hostName = parts[0];
    if (hasPort) {
      parts = $(parts.last()).splitOnLast("/");
      port = Math.parseInt(parts[0]);
      db = parts.length == 2 ? Math.parseInt(parts[1]) : 0;
    }
  }

  void logDebug (arg) {
    if (logLevel >= LogLevel.Debug) print(arg);
  }
  void logError (arg) {
    if (logLevel >= LogLevel.Error) print(arg);
  }
  Exception createError(arg){
    logError(arg);
    return new Exception(arg);
  }

  Future<bool> ensureConnected() {
    logDebug("ensureConnected()");
    Completer task = new Completer();
    if (_wrapper != null && !_wrapper.closed) {
      task.complete(false);
      return task.future;
    }

    _socket = new Socket(hostName, port);
    _socket.onConnect = () {
      logDebug("connected!");
      _wrapper.isClosed = false;

      void complete(Object ignore) =>
        db > 0
        ? select(db).then((_) => task.complete(true))
        : task.complete(true);

      if (password != null)
        auth(password).then(complete);
      else
        complete(null);
    };
    _inStream = new SocketInputStream(_socket);
    _wrapper = new SocketWrapper(_socket, _inStream);
    _inStream.onClosed = () => close();
    _inStream.onError = (e) {
      logDebug('connect exception ${e}');
      try { close(); } catch(Exception ex){}
      task.completeException(e);
    };

    _socket.onData = onSocketData;
    return task.future;
  }

  Future select(int _db) => sendExpectSuccess(["SELECT".charCodes(), (db = _db).toString().charCodes()]);

  Future auth(String _password) => sendExpectSuccess(["AUTH".charCodes(), (password = _password).charCodes()]);

  onSocketData() {
    int available = _socket.available();
    logDebug("onSocketData: $available total bytes");
    if (available == 0) return;

    while (true) {
      if (pendingReads.length == 0) return;
      ExpectRead expectRead = pendingReads.first(); //peek + read next in queue
      try{
        if (!expectRead.execute(_wrapper)) return;
      }catch(var e){
        logError("ERROR parsing read: $e");
      }
      pendingReads.removeFirst(); //pop if success
    }
  }

  void cmdLog(args){
    logDebug("cmdLog: $args");
  }

  Future sendCommand(List<List> cmdWithArgs){
    Completer task = new Completer();
    ensureConnected().then((_){
      cmdLog(cmdWithArgs);
      writeAllToSendBuffer(cmdWithArgs);
      if (pipeline == null && !flushSendBuffer()) {
        task.completeException(createError("Could not flush socket"));
      }
      task.complete(pipeline == null);
    });

    return task.future;
  }

  bool flushSendBuffer(){
    totalBufferFlushes++;
    logDebug("flushSendBuffer(): ${_socket.available()}");

    int maxAttempts = 100;
    while ((cmdBufferIndex -= _socket.writeList(cmdBuffer, 0, cmdBufferIndex)) > 0 && --maxAttempts > 0);

    resetSendBuffer();
    return maxAttempts > 0;
  }

  void resetOnError(){
    resetSendBuffer();
  }

  void resetSendBuffer() {
    cmdBufferIndex = 0;
  }

  List getCmdBytes(String cmdPrefix, int noOfLines){
    String strLines = noOfLines.toString();
    int strLinesLen = strLines.length;

    List bytes = new Int8List(1 + strLinesLen + 2);
    bytes[0] = cmdPrefix.charCodeAt(0);
    List strBytes = strLines.charCodes();
    bytes.setRange(1, strBytes.length, strBytes);
    bytes[1 + strLinesLen] = _Utils.CR;
    bytes[2 + strLinesLen] = _Utils.LF;

    return bytes;
  }

  void writeAllToSendBuffer(List<List> cmdWithArgs){
    writeToSendBuffer(getCmdBytes('*', cmdWithArgs.length));
    for (List safeBinaryValue in cmdWithArgs){
      writeToSendBuffer(getCmdBytes(@'$', safeBinaryValue.length));
      writeToSendBuffer(safeBinaryValue);
      writeToSendBuffer(endData);
    }
  }

  void writeToSendBuffer(List cmdBytes){
    if ((cmdBufferIndex + cmdBytes.length) > cmdBuffer.length) {
      logDebug("resizing sendBuffer $cmdBufferIndex + ${cmdBytes.length} + $breathingSpace");
      totalBufferResizes++;
      Int8List newLargerBuffer = new Int8List(cmdBufferIndex + cmdBytes.length + breathingSpace);
      cmdBuffer.setRange(0, cmdBuffer.length, newLargerBuffer);
      cmdBuffer = newLargerBuffer;
    }
    cmdBuffer.setRange(cmdBufferIndex, cmdBytes.length, cmdBytes);
    cmdBufferIndex += cmdBytes.length;

    totalBuffersWrites++;
    totalBytesWritten += cmdBytes.length;
  }

  void queueRead(Completer task, void reader(InputStream stream, Completer task)){
    pendingReads.add(new ExpectRead(task, reader));
    logDebug("queueRead: #${pendingReads.length}");
  }

  Future<Object> sendExpectSuccess(List<List> cmdWithArgs){
    Completer task = new Completer();
    sendCommand(cmdWithArgs)
    .then((_){
      if (pipeline != null)
        pipeline.completeVoidQueuedCommand(_Utils.expectSuccess);
      else
        queueRead(task, _Utils.expectSuccess);
    });
    return task.future;
  }

  Future<bool> sendExpectIntSuccess(List<List> cmdWithArgs) =>
    sendExpectInt(cmdWithArgs).transform((success) => success == 1);

  Future<int> sendExpectInt(List<List> cmdWithArgs){
    Completer task = new Completer();
    sendCommand(cmdWithArgs)
    .then((_){
      if (pipeline != null)
        pipeline.completeIntQueuedCommand(_Utils.readInt);
      else
        queueRead(task, _Utils.readInt);
    });
    return task.future;
  }

  Future<List<int>> sendExpectData(List<List> cmdWithArgs){
    Completer task = new Completer();
    sendCommand(cmdWithArgs)
    .then((_){
      if (pipeline != null)
        pipeline.completeBytesQueuedCommand(_Utils.readData);
      else
        queueRead(task, _Utils.readData);
    });
    return task.future;
  }

  Future<List<List<int>>> sendExpectMultiData(List<List> cmdWithArgs){
    Completer task = new Completer();
    sendCommand(cmdWithArgs)
    .then((_){
      if (pipeline != null)
        pipeline.completeMultiBytesQueuedCommand(_Utils.readMultiData);
      else
        queueRead(task, _Utils.readMultiData);
    });
    return task.future;
  }

  Future<String> sendExpectString(List<List> cmdWithArgs) =>
    sendExpectData(cmdWithArgs).transform((List<int> bytes) => new String.fromCharCodes(bytes));

  Future<double> sendExpectDouble(List<List> cmdWithArgs) =>
    sendExpectData(cmdWithArgs).transform((List<int> bytes) => Math.parseDouble(new String.fromCharCodes(bytes)));

  Future<String> sendExpectCode(List<List> cmdWithArgs){
    Completer task = new Completer();
    sendCommand(cmdWithArgs)
    .then((_){
      if (pipeline != null)
        pipeline.completeStringQueuedCommand(_Utils.expectCode);
      else
        queueRead(task, _Utils.expectCode);
    });
    return task.future;
  }

  bool get closed() => _inStream == null || _inStream.closed;



  close() {
    logDebug("closing..");
    if (_inStream != null) _inStream.close();
    if (_socket != null){
      _socket.onData = null;
      _socket.onWrite = null;
      _socket.onError = null;
      _socket.close();
    }
    if (_wrapper != null) _wrapper.isClosed = true;
    _inStream = null;
    _socket = null;
    _wrapper = null;
  }
}


class _Utils {
  static final int CR = 13;
  static final int LF = 10;
  static final int DASH = 45;    // -
  static final int DOLLAR = 36;  // $
  static final int COLON = 58;   // :
  static final int ASTERIX = 42; // *

  static final NoMoreData = null;

  static void logDebug(arg){
    //print("$arg");
  }
  static void logError(arg){
    print("$arg");
  }

  static Exception createError(arg){
    logError(arg);
    return new Exception(arg);
  }

  static int readByte(InputStream stream){
    List<int> ret = stream.read(1);
    return ret != NoMoreData ? ret[0] : NoMoreData;
  }

  static List<int> readLine(InputStream stream){
    logDebug("readLine: ${stream.available()} total bytes");
    List<int> buffer = new List<int>();
    List<int> ret;
    int c;
    while ((ret = stream.read(1)) != null){
      c = ret[0];
      if (c == CR) continue;
      if (c == LF) break;
      buffer.add(c);
    }
    return buffer;
  }

  static String readString(InputStream stream) => new String.fromCharCodes(readLine(stream));

  static String parseError(String redisError) =>
    redisError == null || redisError.length < 3 || !redisError.startsWith("ERR")
      ? redisError
      : redisError.substring(4);

  static void parseLine(InputStream stream, Completer task, void callback(int charPrefix, String line)){
    logDebug("parseLine: ${stream.available()} total bytes");
    int c = readByte(stream);
    if (c == NoMoreData) return NoMoreData;

    String line = readString(stream);
    logDebug("$c$line");

    if (c == DASH)
      task.completeException(createError(parseError(line)));

    callback(c, line);
  }

  static void expectSuccess(InputStream stream, Completer task) =>
    parseLine(stream, task, (int c, String line) => task.complete(null));

  static void expectCode(InputStream stream, Completer task) =>
    parseLine(stream, task, (int c, String line) => task.complete(line));

  static Function expectWordFn(String word) {
    return (InputStream stream, Completer task) {
      parseLine(stream, task, (int c, String line) {
        if (line != word)
          task.completeException(createError("Expected $word got $line"));
        task.complete(null);
      });
    };
  }
  static void expectOk(InputStream stream, Completer task) => expectWordFn("OK")(stream, task);
  static void expectQueued(InputStream stream, Completer task) => expectWordFn("QUEUED")(stream, task);

  static void readInt(InputStream stream, Completer task){
    parseLine(stream, task, (int c, String line) {
      if (c == COLON || c == DOLLAR){
        int ret = null;
        try {
          ret = Math.parseInt(line);
        }catch (var e){
          task.completeException(createError("Unknown reply in readInt: $c/$line"));
          return;
        }
        task.complete(ret);
        return;
      }
      task.completeException(createError("Unknown reply on integer response: $c/$line"));
    });
  }

  static void readData(InputStream stream, Completer task){
    List<int> bytes = readLine(stream);
    String line = new String.fromCharCodes(bytes);
    logDebug("readData: $line");
    if (bytes.length == 0) return NoMoreData;

    int c = bytes[0];
    if (c == DOLLAR){
      if (line == @"$-1") {
        task.complete(null);
        return;
      }

      int count;
      try {
        count = Math.parseInt(line.substring(1));
      }catch (var e){
        task.completeException(createError("readData: Invalid length: $line: $e"));
        return null;
      }
      if (stream.available() < count) return;

      int offset = 0;
      List<int> buffer = stream.read(count);

      List<int> eol = stream.read(2);
      if (eol.length != 2 || eol[0] != _Utils.CR || eol[1] != _Utils.LF){
        task.completeException(createError("Invalid termination: $eol"));
      }
      else{
        task.complete(buffer);
      }
    }
    else if (c == COLON){
      task.complete(bytes.getRange(1, bytes.length -1));
      return;
    } else {
      task.completeException(createError("Unexpected reply: $line"));
    }
 }

  static void readMultiData(InputStream stream, Completer task){
    parseLine(stream, task, (int c, String line) {
      if (c == ASTERIX){
        int dataCount = null;
        try{
          dataCount = Math.parseInt(line);
        }catch (var e){
          task.completeException(createError("readMultiData: Unknown reply on integer response: $c$line: $e"));
          return;
        }
        List<List<int>> ret = new List<List<int>>();
        if (dataCount == -1){
          task.complete(ret);
          return;
        }

        for (int i=0; i<dataCount; i++){
          Completer<List<int>> dataTask = new Completer<List<int>>();
          readData(stream, dataTask);
          if (!dataTask.future.isComplete) {
            task.completeException(createError("readMultiData: Expected synchronus result, aborting..."));
            return;
          }
          if (dataTask.future.exception != null) {
            task.completeException(dataTask.future.exception);
            return;
          }
          ret.add(dataTask.future.value);
        }

        try{
          task.complete(ret);
        }catch(var e){
          logError("readMultiData: task.complete(ret): $e");
          throw e;
        }
      } else {
        task.completeException(createError("Unknown reply on integer response: $c$line"));
      }
    });
  }
}

class SocketWrapper {
  Socket socket;
  SocketInputStream inStream;
  bool isClosed;

  //stats
  int totalRewinds = 0;
  int totalReads = 0;
  int totalReadIntos = 0;
  int totalBytesRead = 0;

  Map get stats() => {
    'rewinds': totalRewinds,
    'reads': totalReads,
    'bytesRead': totalBytesRead,
//    'readIntos': totalReadIntos,
  };

  SocketWrapper(Socket this.socket, SocketInputStream this.inStream);

  //The Stream takes over the close event + manages the socket close lifecycle
  bool get closed() => isClosed != null ? isClosed : inStream.closed;

  void pipe(OutputStream output, [bool close]) { inStream.pipe(output, close); }
}

//Records what's read so can be replayed if all data hasn't been received.
class SocketBuffer implements InputStream {
  List<int> _buffer;
  int _position = 0;
  List<List<int>> _chunks;
  Socket _socket;
  SocketWrapper _wrapper;

  SocketBuffer(SocketWrapper _wrapper)
    : _chunks = new List<List<int>>(),
      this._wrapper = _wrapper,
      _socket = _wrapper.socket;

  int get remaining() => _buffer == null ? 0 : _buffer.length - _position;

  //if a full response cannot be read from the stream, the client gives up,
  //rewinds the partially read buffer, and re-attempts processing the response on next onData event
  void rewind(){
    _wrapper.totalRewinds++;

    int bufferSize = $(_chunks.map((x) => x.length)).sum();
    //merge all recorded chunks into a single buffer for easy reading
    _buffer = new Int8List(bufferSize);
    int i = 0;
    for (List<int> chunk in _chunks){
      _buffer.setRange(i, chunk.length, chunk);
      i += chunk.length;
    }
    _chunks = new List<List<int>>();
    _position = 0;
  }

  List<int> readBuffer([int len]){
    if (len == null) len = remaining;
    if (len > remaining)
      throw new Exception("Can't read $len bytes with only $remaining remaining");

    List<int> buffer = new Int8List(len);
    buffer.setRange(0, len, buffer, _position);
    _position += len;

    return buffer;
  }

  List<int> read([int len]) {
    int bytesToRead = remaining + available();
    if (bytesToRead == 0) return null;
    if (len !== null) {
      if (len <= 0)
        throw new Exception("Illegal length $len, available: $bytesToRead");
      else if (bytesToRead > len)
        bytesToRead = len;
    }
//    print("SocketBuffer.read() $len / $bytesToRead ($remaining/${available()})");
    Int8List buffer = new Int8List(bytesToRead);

    //Read from buffer
    int bytesRead = 0;
    int readFromBuffer = Math.min(bytesToRead, remaining);
    if (readFromBuffer > 0){
      buffer.setRange(0, readFromBuffer, _buffer, _position);
      _position += readFromBuffer;
      bytesRead += readFromBuffer;
    }
    bytesToRead -= readFromBuffer;

    //Read from socket
    bytesRead += readInto(buffer, readFromBuffer, bytesToRead);

    _wrapper.totalReads++;
    _wrapper.totalBytesRead += len;

    if (bytesRead == 0) {
      // On MacOS when reading from a tty Ctrl-D reports 1 byte available, 0 bytes read
      return null;
    } else if (bytesRead < buffer.length) {
      //re-size the buffer
      Int8List newBuffer = new Int8List(bytesRead);
      newBuffer.setRange(0, bytesRead, buffer);
      return newBuffer;
    } else {
      return buffer;
    }
  }

  int readInto(List<int> buffer, [int offset = 0, int len]) {
//    print("readInto: ${buffer.length} off: $offset len: $len, closed: $closed");
    if (closed) return null;
    if (len === null) len = buffer.length;
    if (offset < 0) throw new Exception("Illegal offset $offset");
    if (len < 0) throw new Exception("Illegal length $len");

    int bytesRead = _socket.readList(buffer, offset, len);
    List<int> chunk = buffer.getRange(offset, bytesRead);
    _chunks.add(chunk);

    _wrapper.totalReadIntos++;
    _wrapper.totalBytesRead += bytesRead;

    return bytesRead;
  }

  int available() => _socket.available();
  void pipe(OutputStream output, [bool close]) { _wrapper.pipe(output, close); }
  void close() => _socket.close();
  bool get closed() => _wrapper.closed;
  void set onData(void callback()) { _socket.onData = callback; }
  void set onClosed(void callback()) { _socket.onClosed = callback; }
  void set onError(void callback(e)) { _socket.onError = callback; }
}
