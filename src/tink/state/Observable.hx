package tink.state;

import tink.state.Promised;

using tink.CoreApi;

abstract Observable<T>(ObservableObject<T>) from ObservableObject<T> to ObservableObject<T> {
  
  static var stack = new List();
  
  public var value(get, never):T;
  
    @:to function get_value() {
      var before = stack.first();
        
      stack.push(this);
      var ret = this.value;
      switch Std.instance(before, AutoObservable) {
        case null: 
        case v:
          v.subscribeTo(this);
      }
      stack.pop();
      return ret;
    }
      
  public function nextTime(check:T->Bool):Future<T> {
    var ret = Future.trigger();
    var binding = bind(function (v) {
      if (check(v)) ret.trigger(v);
    });
    ret.asFuture().handle(binding);
    return ret;
  }
    
  function changed()
    return this.changed;
  
  public inline function new(get, changed)
    this = new BasicObservable<T>(get, changed);
    
  public function combine<A, R>(that:Observable<A>, f:T->A->R) 
    return new Observable<R>(
      function () return f(this.value, that.value), 
      this.changed.join(that.changed())
    );
    
  public function join(that:Observable<T>) {
    var lastA = null;
    return combine(that, function (a, b) {
      var ret = 
        if (lastA == a) b;
        else a;
        
      lastA = a;
      return ret;
    });
  }
  
  public function map<R>(f:Transform<T, R>) 
    return new Observable<R>(
      function () return f(this.value),
      this.changed
    );
  
  public function combineAsync<A, R>(that:Observable<A>, f:T->A->Promise<R>):Observable<Promised<R>>
     return combine(that, f).mapAsync(function (x) return x);
  
  public function mapAsync<R>(f:T->Promise<R>):Observable<Promised<R>> {
    var ret = new State(Loading),
        link:CallbackLink = null;
        
    bind(function (data) {
      link.dissolve();
      ret.set(Loading);
      link = f(data).handle(function (r) ret.set(switch r {
        case Success(v): Done(v);
        case Failure(v): Failed(v);
      }));
    });
    
    return ret;
  } 
  
  public function switchSync<R>(cases:Array<{ when: T->Bool, then: Lazy<Observable<R>> }>, dfault:Lazy<Observable<R>>):Observable<R> {
    var trigger = Signal.trigger();
    
    function fire(_)
      trigger.trigger(Noise);
    
    this.changed.handle(fire);
    
    return new Observable(function () {
      
      var matched = dfault,
          value = value;
          
      for (c in cases) 
        if (c.when(value)) {
          matched = c.then;
          break;
        }
        
      var ret = matched.get();
      
      ret.changed().next().handle(fire);
      
      return ret.value;
          
    }, trigger);
  }
    
  public function bind(?options:{ ?direct: Bool }, cb:Callback<T>):CallbackLink
    return 
      switch options {
        case null | { direct: null | false }:
          
          cb.invoke(value); 
          this.changed.handle(function () cb.invoke(value));
          
        default: 
                      
          var scheduled = false,
              active = true,
              update = function () if (active) {
                cb.invoke(value);
                scheduled = false;
              }
          
          function doSchedule() {
            if (scheduled) return;
            
            scheduled = true;
            schedule(update);
          }    
          
          doSchedule();
              
          var link = this.changed.handle(doSchedule);
          
          return function () 
            if (active) {
              active = false;
              link.dissolve();
            }
      }
      
  static var scheduled:Array<Void->Void> = 
    #if (js || tink_runloop) 
      [];
    #else
      null;
    #end
  
  static function schedule(f:Void->Void) 
    switch scheduled {
      case null:
        f();
      case []:
        scheduled.push(f);
        #if tink_runloop
          tink.RunLoop.current.atNextStep(updateAll);
        #elseif js
          js.Browser.window.requestAnimationFrame(function (_) updateAll());
        #else
          throw 'this should be unreachable';
        #end
      case v:
        v.push(f);
    }
  
  static public function updateAll() {
    var old = scheduled;
    scheduled = null;
    
    for (o in old) o();
    
    scheduled = [];
  }  
  
  @:from static inline function ofConvertible<T>(o: { function toObservable():Observable<T>; } )
    return o.toObservable();
    
  @:from static function ofPromised<T>(p:Promise<Observable<T>>):Observable<Promised<T>> {
    
    var state:Promised<Observable<T>> = Loading;
    var changed = Signal.trigger();
    
    p.handle(function (o) {
      switch o {
        case Success(data):
          state = Done(data);
          data.changed().handle(changed.trigger);
        case Failure(e):
          state = Failed(e);
      }
      changed.trigger(Noise);
    });
    return new Observable(
      function () return switch state {
        case Loading: Loading;
        case Done(o): Done(o.value);
        case Failed(e): Failed(e);
      },
      changed
    );
  }
  
  @:from static public function auto<T>(f:Void->T):Observable<T>
    return new AutoObservable(f);
  
  @:noUsing @:from static public function const<T>(value:T):Observable<T> 
    return new ConstObservable(value);
      
}


@:callable
abstract Transform<T, R>(T->R) {
  
  @:from static function ofNaive<T, R>(f:T->R):Transform<Promised<T>, Promised<R>> 
    return function (p) return switch p {
      case Failed(e): Failed(e);
      case Loading: Loading;
      case Done(v): Done(f(v));
    }
  
  @:from static function ofExact<T, R>(f:T->R):Transform<T, R>
    return cast f;
}

interface ObservableObject<T> {
  public var changed(get, never):Signal<Noise>;
  public var value(get, never):T;  
}

private class ConstObservable<T> implements ObservableObject<T> {
  
  static var NEVER = new Signal<Noise>(function (_) return null);
  
  public var value(get, null):T;
    inline function get_value()
      return value;
      
  public var changed(get, null):Signal<Noise>;
    inline function get_changed()
      return NEVER;
      
  public function new(value)
    this.value = value;
}

private class AutoObservable<T> extends BasicObservable<T> {
  
  var trigger:SignalTrigger<Noise>;
  var dependencies:Array<{}> = [];
  var links:Array<CallbackLink> = [];
  
  public function new(getValue:Void->T) {
    
    this.trigger = Signal.trigger();
    this.trigger.asSignal().handle(function () {
      dependencies = [];
      for (l in links)
        l.dissolve();
      links = [];
    });
    
    super(function () {  
      return getValue();
    }, trigger);
  }
  
  public function subscribeTo<X>(observable:ObservableObject<X>) 
    switch dependencies.indexOf(observable) {
      case -1:
        dependencies.push(observable);
        links.push(observable.changed.handle(trigger.trigger));
      default:
    }

}

private class BasicObservable<T> implements ObservableObject<T> {
  
  var getValue:Void->T;
  var valid:Bool;
  var cache:T;
  
  public var changed(get, null):Signal<Noise>;  
  
    inline function get_changed()
      return changed;
      
  public var value(get, never):T;
    function get_value() {
      if (!valid) {
        cache = getValue();
        valid = true;
      }
      return cache;
    }
    
  public function new(getValue, changed:Signal<Noise>) {
    this.getValue = getValue;
    this.changed = changed.filter(function (_) return valid && !(valid = false));//the things you do for neat output ...
  }
    
}