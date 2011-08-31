package net.gimite.websocket {

import flash.events.Event;

/**
 * This class represents a generic websocket event.  It contains the standard "type"
 * parameter as well as a "message" parameter.
 */
public class WebSocketEvent extends Event {
  
  public static const OPEN:String = "open";
  public static const CLOSE:String = "close";
  public static const MESSAGE:String = "message";
  public static const ERROR:String = "error";

  public var message:String;
  public var binary:Boolean;
  
  public function WebSocketEvent(
      type:String, message:String = null, binary:Boolean = false,
      bubbles:Boolean = false, cancelable:Boolean = false) {
    super(type, bubbles, cancelable);
    this.message = message;
    this.binary = binary;
  }
  
  public override function clone():Event {
    return new WebSocketEvent(this.type, this.message, this.bubbles, this.cancelable);
  }
  
  public override function toString():String {
    return "WebSocketEvent: " + this.type + ": " + this.message;
  }
}

}
