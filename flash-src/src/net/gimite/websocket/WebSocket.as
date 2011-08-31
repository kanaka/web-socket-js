// Copyright: Hiroshi Ichikawa <http://gimite.net/en/>
// License: New BSD License
// Reference: http://dev.w3.org/html5/websockets/
// Reference: http://tools.ietf.org/html/draft-ietf-hybi-thewebsocketprotocol-12

package net.gimite.websocket {

import com.adobe.net.proxies.RFC2817Socket;
import com.gsolo.encryption.MD5;
import com.gsolo.encryption.SHA1;
import com.hurlant.crypto.tls.TLSConfig;
import com.hurlant.crypto.tls.TLSEngine;
import com.hurlant.crypto.tls.TLSSecurityParameters;
import com.hurlant.crypto.tls.TLSSocket;

import flash.display.*;
import flash.events.*;
import flash.external.*;
import flash.net.*;
import flash.system.*;
import flash.utils.*;

import mx.controls.*;
import mx.core.*;
import mx.events.*;
import mx.utils.*;

public class WebSocket extends EventDispatcher {
  
  private static var CONNECTING:int = 0;
  private static var OPEN:int = 1;
  private static var CLOSING:int = 2;
  private static var CLOSED:int = 3;
  private static var GUID:String = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
  
  private var id:int;
  private var rawSocket:Socket;
  private var tlsSocket:TLSSocket;
  private var tlsConfig:TLSConfig;
  private var socket:Socket;
  private var url:String;
  private var scheme:String;
  private var host:String;
  private var port:uint;
  private var path:String;
  private var origin:String;
  private var requestedProtocols:Array;
  private var acceptedProtocol:String;
  private var buffer:ByteArray = new ByteArray();
  private var headerState:int = 0;
  private var readyState:int = CONNECTING;
  private var cookie:String;
  private var headers:String;
  private var expectedDigest:String;
  private var logger:IWebSocketLogger;
  private var b64encoder:Base64Encoder = new Base64Encoder();

  private var frame_fin:int = -1;
  private var frame_opcode:int = -1;
  private var frame_hlength:uint = 0;
  private var frame_plength:uint = 0;

  public function WebSocket(
      id:int, url:String, protocols:Array, origin:String,
      proxyHost:String, proxyPort:int,
      cookie:String, headers:String,
      logger:IWebSocketLogger) {
    this.logger = logger;
    this.id = id;
    this.url = url;
    var m:Array = url.match(/^(\w+):\/\/([^\/:]+)(:(\d+))?(\/.*)?(\?.*)?$/);
    if (!m) fatal("SYNTAX_ERR: invalid url: " + url);
    this.scheme = m[1];
    this.host = m[2];
    var defaultPort:int = scheme == "wss" ? 443 : 80;
    this.port = parseInt(m[4]) || defaultPort;
    this.path = (m[5] || "/") + (m[6] || "");
    this.origin = origin;
    this.requestedProtocols = protocols;
    this.cookie = cookie;
    // if present and not the empty string, headers MUST end with \r\n
    // headers should be zero or more complete lines, for example
    // "Header1: xxx\r\nHeader2: yyyy\r\n"
    this.headers = headers;
    
    if (proxyHost != null && proxyPort != 0){
      if (scheme == "wss") {
        fatal("wss with proxy is not supported");
      }
      var proxySocket:RFC2817Socket = new RFC2817Socket();
      proxySocket.setProxyInfo(proxyHost, proxyPort);
      proxySocket.addEventListener(ProgressEvent.SOCKET_DATA, onSocketData);
      rawSocket = socket = proxySocket;
    } else {
      rawSocket = new Socket();
      if (scheme == "wss") {
        tlsConfig= new TLSConfig(TLSEngine.CLIENT,
            null, null, null, null, null,
            TLSSecurityParameters.PROTOCOL_VERSION);
        tlsConfig.trustAllCertificates = true;
        tlsConfig.ignoreCommonNameMismatch = true;
        tlsSocket = new TLSSocket();
        tlsSocket.addEventListener(ProgressEvent.SOCKET_DATA, onSocketData);
        socket = tlsSocket;
      } else {
        rawSocket.addEventListener(ProgressEvent.SOCKET_DATA, onSocketData);
        socket = rawSocket;
      }
    }
    rawSocket.addEventListener(Event.CLOSE, onSocketClose);
    rawSocket.addEventListener(Event.CONNECT, onSocketConnect);
    rawSocket.addEventListener(IOErrorEvent.IO_ERROR, onSocketIoError);
    rawSocket.addEventListener(SecurityErrorEvent.SECURITY_ERROR, onSocketSecurityError);
    rawSocket.connect(host, port);
  }
  
  /**
   * @return  This WebSocket's ID.
   */
  public function getId():int {
    return this.id;
  }
  
  /**
   * @return this WebSocket's readyState.
   */
  public function getReadyState():int {
    return this.readyState;
  }

  public function getAcceptedProtocol():String {
    return this.acceptedProtocol;
  }
  
  public function send(dType:String, encData:String):int {
    var raw_str:String = decodeURIComponent(encData);
    var data:ByteArray;
    if(dType == "s") {
      data = new ByteArray();
      data.writeUTFBytes(raw_str);
    } else {
      data = stringToByteArray(raw_str);
    }
    var plength:uint = data.length;

    if (readyState == OPEN) {
      var header:ByteArray = new ByteArray();

      if(dType == "s") {
        header.writeByte(0x80 | 0x01); // FIN + text opcode
      } else {
        header.writeByte(0x80 | 0x02); // FIN + binary opcode
      }

      plength = data.length;
      if (plength <= 125) {
        header.writeByte(0x80 | plength); // Masked + length
      } else if (plength > 125 && plength < 65536) {
        header.writeByte(0x80 | 126);     // Masked + 126
        header.writeShort(plength);
      } else if (plength >= 65536 && plength < 4294967296) {
        header.writeByte(0x80 | 127);     // Masked + 127
        header.writeUnsignedInt(0); // zero high order bits
        header.writeUnsignedInt(plength);
      } else {
        fatal("Send frame size too large");
        return 0;
      }

      // Generate a mask
      var mask:Array = new Array(4);
      for (var i:int = 0; i < 4; i++) {
        mask[i] = randomInt(0, 255);
        header.writeByte(mask[i]);
      }
      for (i = 0; i < data.length; i++) {
        data[i] = mask[i%4] ^ data[i];
      }

      socket.writeBytes(header);
      socket.writeBytes(data);
      socket.flush();
      logger.log("sent: " + data);
      return -1;
    } else if (readyState == CLOSING || readyState == CLOSED) {
      return plength;
    } else {
      fatal("invalid state");
      return 0;
    }
  }

  private function stringToByteArray(s:String):ByteArray
  {
    var a:ByteArray = new ByteArray();
    for (var i:int = 0; i < s.length; ++i)
      a[i] = s.charCodeAt(i);
    return a;
  }

  public function parseFrame():int {
    var cur_pos:int = buffer.position;

    frame_hlength = 2;
    if (buffer.length < frame_hlength) {
      return -1;
    }

    frame_opcode  = buffer[0] & 0x0f;
    frame_fin     = (buffer[0] & 0x80) >> 7;
    frame_plength = buffer[1] & 0x7f;

    if (frame_plength == 126) {
      frame_hlength = 4;
      if (buffer.length < frame_hlength) {
        return -1;
      }

      buffer.endian = Endian.BIG_ENDIAN;
      buffer.position = 2;
      frame_plength = buffer.readUnsignedShort();
      buffer.position = cur_pos;
    } else if (frame_plength == 127) {
      frame_hlength = 10;
      if (buffer.length < frame_hlength) {
        return -1;
      }

      buffer.endian = Endian.BIG_ENDIAN;
      buffer.position = 2;
      // Protocol allows 64-bit length, but we only handle 32-bit
      var big:uint = buffer.readUnsignedInt(); // Skip high 32-bits
      frame_plength = buffer.readUnsignedInt(); // Low 32-bits
      buffer.position = cur_pos;
      if (big != 0) {
        onError("Frame length exceeds 4294967295. Bailing out!");
        return -1;
      }
    }

    if (buffer.length < frame_hlength + frame_plength) {
      return -1;
    }

    return 1;
  }
  
  public function close(isError:Boolean = false):void {
    logger.log("close");
    try {
      if (readyState == OPEN && !isError) {
        // TODO: send code and reason
        socket.writeByte(0x80 | 0x08); // FIN + close opcode
        socket.writeByte(0x80 | 0x00); // Masked + no payload
        socket.writeUnsignedInt(0x00); // Mask
        socket.flush();
      }
      socket.close();
    } catch (ex:Error) { }
    socket.addEventListener(ProgressEvent.SOCKET_DATA, onSocketData);
    readyState = CLOSED;
    this.dispatchEvent(new WebSocketEvent(isError ? "error" : "close"));
  }
  
  private function onSocketConnect(event:Event):void {
    logger.log("connected");

    if (scheme == "wss") {
      logger.log("starting SSL/TLS");
      tlsSocket.startTLS(rawSocket, host, tlsConfig);
    }
    
    var defaultPort:int = scheme == "wss" ? 443 : 80;
    var hostValue:String = host + (port == defaultPort ? "" : ":" + port);
    var key:String = generateKey();

    SHA1.b64pad = "=";
    expectedDigest = SHA1.b64_sha1(key + GUID);

    var opt:String = "";
    if (requestedProtocols.length > 0) {
      opt += "Sec-WebSocket-Protocol: " + requestedProtocols.join(",") + "\r\n";
    }
    // if caller passes additional headers they must end with "\r\n"
    if (headers) opt += headers;
    
    var req:String = StringUtil.substitute(
      "GET {0} HTTP/1.1\r\n" +
      "Host: {1}\r\n" +
      "Upgrade: websocket\r\n" +
      "Connection: Upgrade\r\n" +
      "Sec-WebSocket-Key: {2}\r\n" +
      "Sec-WebSocket-Origin: {3}\r\n" +
      "Sec-WebSocket-Version: 8\r\n" +
      "Cookie: {4}\r\n" +
      "{5}" +
      "\r\n",
      path, hostValue, key, origin, cookie, opt);
    logger.log("request header:\n" + req);
    socket.writeUTFBytes(req);
    socket.flush();
  }

  private function onSocketClose(event:Event):void {
    logger.log("closed");
    readyState = CLOSED;
    this.dispatchEvent(new WebSocketEvent("close"));
  }

  private function onSocketIoError(event:IOErrorEvent):void {
    var message:String;
    if (readyState == CONNECTING) {
      message = "cannot connect to Web Socket server at " + url + " (IoError: " + event.text + ")";
    } else {
      message =
          "error communicating with Web Socket server at " + url +
          " (IoError: " + event.text + ")";
    }
    onError(message);
  }

  private function onSocketSecurityError(event:SecurityErrorEvent):void {
    var message:String;
    if (readyState == CONNECTING) {
      message =
          "cannot connect to Web Socket server at " + url + " (SecurityError: " + event.text + ")\n" +
          "make sure the server is running and Flash socket policy file is correctly placed";
    } else {
      message =
          "error communicating with Web Socket server at " + url +
          " (SecurityError: " + event.text + ")";
    }
    onError(message);
  }
  
  private function onError(message:String):void {
    if (readyState == CLOSED) return;
    logger.error(message);
    close(readyState != CONNECTING);
  }

  private function onSocketData(event:ProgressEvent):void {
    var pos:int = buffer.length;
    socket.readBytes(buffer, pos);
    for (; pos < buffer.length; ++pos) {
      if (headerState < 4) {
        // try to find "\r\n\r\n"
        if ((headerState == 0 || headerState == 2) && buffer[pos] == 0x0d) {
          ++headerState;
        } else if ((headerState == 1 || headerState == 3) && buffer[pos] == 0x0a) {
          ++headerState;
        } else {
          headerState = 0;
        }
        if (headerState == 4) {
          var headerStr:String = readUTFBytes(buffer, 0, pos + 1);
          logger.log("response header:\n" + headerStr);
          if (!validateHandshake(headerStr)) return;
          removeBufferBefore(pos + 1);
          pos = -1;
          readyState = OPEN;
          this.dispatchEvent(new WebSocketEvent("open"));
        }
      } else {
        if (parseFrame() == 1) {
          var data:String = readBytes(buffer, frame_hlength, frame_plength);
          removeBufferBefore(frame_hlength + frame_plength);
          pos = -1;
          if (frame_opcode == 0x01) {
            this.dispatchEvent(new WebSocketEvent("message", encodeURIComponent(data), false));
          } else if (frame_opcode == 0x02) {
            this.dispatchEvent(new WebSocketEvent("message", encodeURIComponent(data), true));
          } else if (frame_opcode == 0x08) {
            // TODO: extract code and reason string
            logger.log("received closing packet");
            close();
          } else {
            // TODO: extract code and reason string
            logger.log("received unknown opcode: " + frame_opcode);
            close();
          }
        }
      }
    }
  }
  
  private function validateHandshake(headerStr:String):Boolean {
    var lines:Array = headerStr.split(/\r\n/);
    if (!lines[0].match(/^HTTP\/1.1 101 /)) {
      onError("bad response: " + lines[0]);
      return false;
    }
    var header:Object = {};
    var lowerHeader:Object = {};
    for (var i:int = 1; i < lines.length; ++i) {
      if (lines[i].length == 0) continue;
      var m:Array = lines[i].match(/^(\S+): (.*)$/);
      if (!m) {
        onError("failed to parse response header line: " + lines[i]);
        return false;
      }
      header[m[1].toLowerCase()] = m[2];
      lowerHeader[m[1].toLowerCase()] = m[2].toLowerCase();
    }
    if (lowerHeader["upgrade"] != "websocket") {
      onError("invalid Upgrade: " + header["Upgrade"]);
      return false;
    }
    if (lowerHeader["connection"] != "upgrade") {
      onError("invalid Connection: " + header["Connection"]);
      return false;
    }
    if (!lowerHeader["sec-websocket-accept"]) {
      onError(
        "The WebSocket server speaks old WebSocket protocol, " +
        "which is not supported by web-socket-js. " +
        "It requires WebSocket protocol HyBi 7. " +
        "Try newer version of the server if available.");
      return false;
    }
    var replyDigest:String = header["sec-websocket-accept"]
    if (replyDigest != expectedDigest) {
      onError("digest doesn't match: " + replyDigest + " != " + expectedDigest);
      return false;
    }
    if (requestedProtocols.length > 0) {
      acceptedProtocol = header["sec-websocket-protocol"];
      if (requestedProtocols.indexOf(acceptedProtocol) < 0) {
        onError("protocol doesn't match: '" +
          acceptedProtocol + "' not in '" + requestedProtocols.join(",") + "'");
        return false;
      }
    }
    return true;
  }

  private function removeBufferBefore(pos:int):void {
    if (pos == 0) return;
    var nextBuffer:ByteArray = new ByteArray();
    buffer.position = pos;
    buffer.readBytes(nextBuffer);
    buffer = nextBuffer;
  }
  
  private function generateKey():String {
    var vals:String = "";
    for (var i:int = 0; i < 16; i++) {
        vals = vals + randomInt(0, 127).toString();
    }
    b64encoder.reset();
    b64encoder.encode(vals);
    return b64encoder.toString();
  }
  
  // Writes byte sequence to socket.
  // bytes is String in special format where bytes[i] is i-th byte, not i-th character.
  private function writeBytes(bytes:String):void {
    for (var i:int = 0; i < bytes.length; ++i) {
      socket.writeByte(bytes.charCodeAt(i));
    }
  }
  
  // Reads specified number of bytes from buffer, and returns it as special format String
  // where bytes[i] is i-th byte (not i-th character).
  private function readBytes(buffer:ByteArray, start:int, numBytes:int):String {
    buffer.position = start;
    var bytes:String = "";
    for (var i:int = 0; i < numBytes; ++i) {
      // & 0xff is to make \x80-\xff positive number.
      bytes += String.fromCharCode(buffer.readByte() & 0xff);
    }
    return bytes;
  }
  
  private function readUTFBytes(buffer:ByteArray, start:int, numBytes:int):String {
    buffer.position = start;
    var data:String = "";
    for(var i:int = start; i < start + numBytes; ++i) {
      // Workaround of a bug of ByteArray#readUTFBytes() that bytes after "\x00" is discarded.
      if (buffer[i] == 0x00) {
        data += buffer.readUTFBytes(i - buffer.position) + "\x00";
        buffer.position = i + 1;
      }
    }
    data += buffer.readUTFBytes(start + numBytes - buffer.position);
    return data;
  }
  
  private function randomInt(min:uint, max:uint):uint {
    return min + Math.floor(Math.random() * (Number(max) - min + 1));
  }
  
  private function fatal(message:String):void {
    logger.error(message);
    throw message;
  }

  // for debug
  private function dumpBytes(bytes:String):void {
    var output:String = "";
    for (var i:int = 0; i < bytes.length; ++i) {
      output += bytes.charCodeAt(i).toString() + ", ";
    }
    logger.log(output);
  }
  
}

}
