//
//  JSTalk.m
//  jstalk
//
//  Created by August Mueller on 1/15/09.
//  Copyright 2009 Flying Meat Inc. All rights reserved.
//

#import "COScript.h"
#import "COSListener.h"
#import "COSPreprocessor.h"
#import "COScript+Interval.h"

#import "MochaRuntime.h"
#import "MOMethod.h"
#import "MOUndefined.h"
#import "MOBridgeSupportController.h"

extern int *_NSGetArgc(void);
extern char ***_NSGetArgv(void);

static BOOL JSTalkShouldLoadJSTPlugins = YES;
static NSMutableArray *JSTalkPluginList;

@interface Mocha (Private)
- (JSValueRef)setObject:(id)object withName:(NSString *)name;
- (BOOL)removeObjectWithName:(NSString *)name;
- (JSValueRef)callJSFunction:(JSObjectRef)jsFunction withArgumentsInArray:(NSArray *)arguments;
- (id)objectForJSValue:(JSValueRef)value;
@end

@interface COScript (Private)

@end


@implementation COScript

+ (void)listen {
    [COSListener listen];
}

+ (void)setShouldLoadExtras:(BOOL)b {
    JSTalkShouldLoadJSTPlugins = b;
}

+ (void)setShouldLoadJSTPlugins:(BOOL)b {
    JSTalkShouldLoadJSTPlugins = b;
}

- (id)init {
	self = [super init];
	if ((self != nil)) {
        _mochaRuntime = [[Mocha alloc] init];
        
        [self setEnv:[NSMutableDictionary dictionary]];
        [self setShouldPreprocess:YES];
//        
//        [self addExtrasToRuntime];
	}
    
	return self;
}


- (void)dealloc {

    debug(@"%s:%d", __FUNCTION__, __LINE__);
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    [self cleanupIntervals];
    
}

- (void)cleanup {
    [self deleteObjectWithName:@"jstalk"];
    [self deleteObjectWithName:@"coscript"];
    
    [_mochaRuntime shutdown];
    
}

- (void)garbageCollect {
    
    NSTimeInterval start = [NSDate timeIntervalSinceReferenceDate];
    
    [_mochaRuntime garbageCollect];
    
    debug(@"gc took %f seconds", [NSDate timeIntervalSinceReferenceDate] - start);
}


- (JSGlobalContextRef)context {
    return [_mochaRuntime context];
}

NSString *currentCOScriptThreadIdentifier = @"org.jstalk.currentCOScriptHack";

+ (COScript*)currentCOScript {
    return [[[NSThread currentThread] threadDictionary] objectForKey:currentCOScriptThreadIdentifier];
}

- (void)pushAsCurrentCOScript {
    [[[NSThread currentThread] threadDictionary] setObject:self forKey:currentCOScriptThreadIdentifier];
}

- (void)popAsCurrentCOScript {
    [[[NSThread currentThread] threadDictionary] removeObjectForKey:currentCOScriptThreadIdentifier];
}

- (void)pushObject:(id)obj withName:(NSString*)name  {
    [_mochaRuntime setObject:obj withName:name];
}

- (void)deleteObjectWithName:(NSString*)name {
    [_mochaRuntime removeObjectWithName:name];
}


- (id)executeString:(NSString*)str {
    
    return [self executeString:str baseURL:nil];
}

- (id)executeString:(NSString*)str baseURL:(NSURL*)base {
    
//    if (!JSTalkPluginList && JSTalkShouldLoadJSTPlugins) {
//        [COScript loadPlugins];
//    }

    if ([self shouldPreprocess]) {
        
        if (!base && [[_env objectForKey:@"scriptURL"] isKindOfClass:[NSURL class]]) {
            base = [_env objectForKey:@"scriptURL"];
        }
        
        str = [COSPreprocessor preprocessCode:str withBaseURL:base];
    }
    
    [self pushAsCurrentCOScript];
    
    id resultObj = nil;
    
    @try {
        
        resultObj = [_mochaRuntime evalString:str];
        
        if (resultObj == [MOUndefined undefined]) {
            resultObj = nil;
        }
    }
    @catch (NSException *e) {
        
        NSDictionary *d = [e userInfo];
        if ([d objectForKey:@"line"]) {
            if ([_errorController respondsToSelector:@selector(coscript:hadError:onLineNumber:atSourceURL:)]) {
                [_errorController coscript:self hadError:[e reason] onLineNumber:[[d objectForKey:@"line"] integerValue] atSourceURL:nil];
            }
        }
        
        NSLog(@"Exception: %@", [e userInfo]);
        [self printException:e];
    }
    @finally {
        //
    }
    
    [self popAsCurrentCOScript];
    
    return resultObj;
}

- (BOOL)hasFunctionNamed:(NSString*)name {
    
    JSValueRef exception = nil;
    JSStringRef jsFunctionName = JSStringCreateWithUTF8CString([name UTF8String]);
    JSValueRef jsFunctionValue = JSObjectGetProperty([_mochaRuntime context], JSContextGetGlobalObject([_mochaRuntime context]), jsFunctionName, &exception);
    JSStringRelease(jsFunctionName);
    
    
    return jsFunctionValue && (JSValueGetType([_mochaRuntime context], jsFunctionValue) == kJSTypeObject);
}

- (id)callFunctionNamed:(NSString*)name withArguments:(NSArray*)args {
    
    id returnValue = nil;
    
    @try {
        
        [self pushAsCurrentCOScript];
        
        returnValue = [_mochaRuntime callFunctionWithName:name withArgumentsInArray:args];
        
        if (returnValue == [MOUndefined undefined]) {
            returnValue = nil;
        }
    }
    @catch (NSException * e) {
        NSLog(@"Exception: %@", e);
        [self printException:e];
    }
    
    [self popAsCurrentCOScript];
    
    return returnValue;
}


- (id)callJSFunction:(JSObjectRef)jsFunction withArgumentsInArray:(NSArray *)arguments {
    [self pushAsCurrentCOScript];
    
    //[self garbageCollect];
    
    JSValueRef r = nil;
    @try {
        r = [_mochaRuntime callJSFunction:jsFunction withArgumentsInArray:arguments];
    }
    @catch (NSException * e) {
        NSLog(@"Exception: %@", e);
        NSLog(@"Info: %@", [e userInfo]);
        [self printException:e];
    }
    
    [self popAsCurrentCOScript];
    
    if (r) {
        return [_mochaRuntime objectForJSValue:r];
    }
    
    return nil;
}

- (void)unprotect:(id)o {
    
    
    
    JSValueRef value = [_mochaRuntime JSValueForObject:o];
    
    assert(value);
    
    if (value) {
        
        JSObjectRef jsObject = JSValueToObject([_mochaRuntime context], value, NULL);
        id private = (__bridge id)JSObjectGetPrivate(jsObject);
        
        assert([private representedObject] == o);
        
        debug(@"COS unprotecting %@", o);
        JSValueUnprotect([_mochaRuntime context], value);
    }
}

- (void)protect:(id)o {
    
    
    JSValueRef value = [_mochaRuntime JSValueForObject:o];
    
    
    assert(value);
    
    if (value) {
        
        JSObjectRef jsObject = JSValueToObject([_mochaRuntime context], value, NULL);
        
        
        debug(@"COS protecting %@ / v: %p o: %p", o, value, jsObject);
        
        id private = (__bridge id)JSObjectGetPrivate(jsObject);
        
        assert([private representedObject] == o);
        
        JSValueProtect([_mochaRuntime context], value);
    }
}

// JavaScriptCore isn't safe for recursion.  So calling this function from
// within a script is a really bad idea.  Of couse, that's what it was written
// for, so it really needs to be taken out.

- (void)include:(NSString*)fileName {
    
    if (![fileName hasPrefix:@"/"] && [_env objectForKey:@"scriptURL"]) {
        NSString *parentDir = [[[_env objectForKey:@"scriptURL"] path] stringByDeletingLastPathComponent];
        fileName = [parentDir stringByAppendingPathComponent:fileName];
    }
    
    NSURL *scriptURL = [NSURL fileURLWithPath:fileName];
    NSError *err = nil;
    NSString *str = [NSString stringWithContentsOfURL:scriptURL encoding:NSUTF8StringEncoding error:&err];
    
    if (!str) {
        NSLog(@"Could not open file '%@'", scriptURL);
        NSLog(@"Error: %@", err);
        return;
    }
    
    if (_shouldPreprocess) {
        str = [COSPreprocessor preprocessCode:str];
    }
    
    [_mochaRuntime evalString:str];
}

- (void)printException:(NSException*)e {
    
    NSMutableString *s = [NSMutableString string];
    
    [s appendFormat:@"%@\n", e];
    
    NSDictionary *d = [e userInfo];
    
    for (id o in [d allKeys]) {
        [s appendFormat:@"%@: %@\n", o, [d objectForKey:o]];
    }
    
    [self print:s];
}

- (void)print:(NSString*)s {
    
    if (_printController && [_printController respondsToSelector:@selector(print:)]) {
        [_printController print:s];
    }
    else {
        if (![s isKindOfClass:[NSString class]]) {
            s = [s description];
        }
        
        printf("%s\n", [s UTF8String]);
    }
}


+ (id)applicationOnPort:(NSString*)port {
    
    NSConnection *conn  = nil;
    NSUInteger tries    = 0;
    
    while (!conn && tries < 10) {
        
        conn = [NSConnection connectionWithRegisteredName:port host:nil];
        tries++;
        if (!conn) {
            debug(@"Sleeping, waiting for %@ to open", port);
            sleep(1);
        }
    }
    
    if (!conn) {
        NSBeep();
        NSLog(@"Could not find a JSTalk connection to %@", port);
    }
    
    return [conn rootProxy];
}

+ (id)application:(NSString*)app {
    
    NSString *appPath = [[NSWorkspace sharedWorkspace] fullPathForApplication:app];
    
    if (!appPath) {
        NSLog(@"Could not find application '%@'", app);
        // fixme: why are we returning a bool?
        return [NSNumber numberWithBool:NO];
    }
    
    NSBundle *appBundle = [NSBundle bundleWithPath:appPath];
    NSString *bundleId  = [appBundle bundleIdentifier];
    
    // make sure it's running
	NSArray *runningApps = [[NSWorkspace sharedWorkspace] runningApplications];
    
    BOOL found = NO;
    
    for (NSRunningApplication *rapp in runningApps) {
        
        if ([[rapp bundleIdentifier] isEqualToString:bundleId]) {
            found = YES;
            break;
        }
        
    }
    
	if (!found) {
        BOOL launched = [[NSWorkspace sharedWorkspace] launchAppWithBundleIdentifier:bundleId
                                                                             options:NSWorkspaceLaunchWithoutActivation | NSWorkspaceLaunchAsync
                                                      additionalEventParamDescriptor:nil
                                                                    launchIdentifier:nil];
        if (!launched) {
            NSLog(@"Could not open up %@", appPath);
            return nil;
        }
    }
    
    
    return [self applicationOnPort:[NSString stringWithFormat:@"%@.JSTalk", bundleId]];
}

+ (id)app:(NSString*)app {
    return [self application:app];
}

+ (id)proxyForApp:(NSString*)app {
    return [self application:app];
}


@end



@implementation JSTalk

@end
