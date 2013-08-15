//
//  BITAuthenticator
//  HockeySDK
//
//  Created by Stephan Diederich on 08.08.13.
//
//

#import "BITAuthenticator.h"
#import "HockeySDK.h"
#import "HockeySDKPrivate.h"
#import "BITAuthenticator_Private.h"
#import "BITHTTPOperation.h"

static NSString* const kBITAuthenticatorAuthTokenKey = @"BITAuthenticatorAuthTokenKey";
static NSString* const kBITAuthenticatorLastAuthenticatedVersionKey = @"BITAuthenticatorLastAuthenticatedVersionKey";

@implementation BITAuthenticator {
  id _appDidBecomeActiveObserver;
  
  UIViewController *_authenticationController;
}

- (void)dealloc {
  [self unregisterObservers];
  [self cancelOperationsWithPath:nil method:nil];
}

- (instancetype) initWithAppIdentifier:(NSString *)appIdentifier isAppStoreEnvironemt:(BOOL)isAppStoreEnvironment {
  self = [super initWithAppIdentifier:appIdentifier isAppStoreEnvironemt:isAppStoreEnvironment];
  if( self ) {
    
  }
  return self;
}

#pragma mark - BITHockeyBaseManager overrides
- (void)startManager {
  [self registerObservers];
  
  switch (self.validationType) {
    case BITAuthenticatorValidationTypeOnAppActive:
      [self validateInstallationWithCompletion:nil];
      break;
    case BITAuthenticatorValidationTypeOnFirstLaunch:
      if(![self.lastAuthenticatedVersion isEqualToString:self.executableUUID]) {
        [self validateInstallationWithCompletion:nil];
      }
      break;
    case BITAuthenticatorValidationTypeNever:
    case BITAuthenticatorValidationTypeOptional:
      break;
  }
}

#pragma mark -
- (NSString *)installationIdentification {
  NSString *authToken = self.authenticationToken;
  if(authToken) {
    return authToken;
  }
  UIDevice *device = self.currentDevice;
  if([device respondsToSelector:@selector(identifierForVendor)]) {
    return self.currentDevice.identifierForVendor.UUIDString;
  } else {
    SEL uniqueIdentifier = NSSelectorFromString(@"uniqueIdentifier");
    if([device respondsToSelector:uniqueIdentifier]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      NSString *uuid = [device performSelector:uniqueIdentifier];
#pragma clang diagnostic pop
      return uuid;
    } else {
      //TODO: what?
      return nil;
    }
  }
}

- (void) validateInstallationWithCompletion:(tValidationCompletion) completion {
  if(nil == self.authenticationToken) {
    [self authenticateWithCompletion:^(NSString *authenticationToken, NSError *error) {
      if(nil == authenticationToken) {
        //if authentication fails, there's nothing to validate
        NSError *error = [NSError errorWithDomain:kBITAuthenticatorErrorDomain
                                             code:BITAuthenticatorNotAuthorized
                                         userInfo:nil];
        if(completion) {
          completion(NO, error);
        } else {
          [self.delegate authenticator:self failedToValidateInstallationWithError:error];
        }
      } else {
        if(completion) {
          completion(YES, nil);
        } else {
          [self.delegate authenticatorDidValidateInstallation:self];
        }
      }
    }];
  } else {
    NSString *validationEndpoint = @"validate";
    __weak typeof (self) weakSelf = self;
    [self getPath:validationEndpoint
       completion:^(BITHTTPOperation *operation, id response, NSError *error) {
         typeof (self) strongSelf = weakSelf;
         if(nil == response) {
           NSDictionary *userInfo = nil;
           if(error) {
             userInfo = @{NSUnderlyingErrorKey : error};
           }
           NSError *error = [NSError errorWithDomain:kBITAuthenticatorErrorDomain
                                                code:BITAuthenticatorNetworkError
                                            userInfo:userInfo];
           [strongSelf validationFailedWithError:error];
         } else {
           NSError *validationParseError = nil;
           BOOL isValidated = [strongSelf.class isValidationResponseValid:response error:&validationParseError];
           if(isValidated) {
             [strongSelf validationSucceeded];
           } else {
             [strongSelf validationFailedWithError:validationParseError];
           }
         }
       }];
  }
}

+ (BOOL) isValidationResponseValid:(id) response error:(NSError **) error {
  NSParameterAssert(response);

  NSError *jsonParseError = nil;
  id jsonObject = [NSJSONSerialization JSONObjectWithData:response
                                                  options:0
                                                    error:&jsonParseError];
  if(nil == jsonObject) {
    if(error) {
      *error = [NSError errorWithDomain:kBITAuthenticatorErrorDomain
                                   code:BITAuthenticatorAPIServerReturnedInvalidRespone
                               userInfo:(jsonParseError ? @{NSUnderlyingErrorKey : jsonParseError} : nil)];
    }
    return NO;
  }
  if(![jsonObject isKindOfClass:[NSDictionary class]]) {
    if(error) {
      *error = [NSError errorWithDomain:kBITAuthenticatorErrorDomain
                                   code:BITAuthenticatorAPIServerReturnedInvalidRespone
                               userInfo:nil];
    }
    return NO;
  }
  
  //TODO: add proper validation
  return [jsonObject[@"isValid"] boolValue];
}

- (void)authenticateWithCompletion:(tAuthenticationCompletion)completion {
  if(_authenticationController) {
    BITHockeyLog(@"Already authenticating. Ignoring request");
    return;
  }
  
  BITAuthenticationViewController *viewController = [[BITAuthenticationViewController alloc] initWithStyle:UITableViewStyleGrouped];
  viewController.delegate = self;
  viewController.authenticator = self;
  switch (self.authenticationType) {
    case BITAuthenticatorAuthTypeEmailAndPassword:
      viewController.requirePassword = YES;
      break;
    case BITAuthenticatorAuthTypeEmail:
      viewController.requirePassword = NO;
      break;
  }
  
  if(viewController) {
    [self.delegate authenticator:self willShowAuthenticationController:viewController];
    _authenticationController = viewController;
    _authenticationCompletionBlock = completion;
    UIViewController *rootViewController = [self.findVisibleWindow rootViewController];
    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:viewController];
    [rootViewController presentModalViewController:navController
                                          animated:YES];
  }
}

#pragma mark - AuthenticationViewControllerDelegate
- (void) authenticationViewControllerDidCancel:(UIViewController*) viewController {
  [viewController dismissModalViewControllerAnimated:YES];
  
  _authenticationController = nil;
  self.authenticationToken = nil;
  NSError *error = [NSError errorWithDomain:kBITAuthenticatorErrorDomain
                                       code:BITAuthenticatorAuthenticationCancelled
                                   userInfo:nil];
  if(self.authenticationCompletionBlock) {
    self.authenticationCompletionBlock(self.authenticationToken, error);
    self.authenticationCompletionBlock = nil;
  } else {
    [self.delegate authenticator:self failedToAuthenticateWithError:error];
  }
}

- (void) authenticationViewController:(UIViewController*) viewController
               authenticatedWithToken:(NSString*) token {
  _authenticationController = nil;
  self.authenticationToken = token;
  if(self.authenticationCompletionBlock) {
    self.authenticationCompletionBlock(self.authenticationToken, nil);
    self.authenticationCompletionBlock = nil;
  } else {
    [self.delegate authenticatorDidAuthenticate:self];
  }
}

#pragma mark - Validation Pseudo-Delegate
- (void)validationFailedWithError:(NSError *)validationError {
  if(self.validationCompletion) {
    self.validationCompletion(NO, validationError);
    self.validationCompletion = nil;
  } else {
    [self.delegate authenticator:self failedToValidateInstallationWithError:validationError];
  }

  switch (self.validationType) {
    case BITAuthenticatorValidationTypeNever:
    case BITAuthenticatorValidationTypeOptional:
      break;
    case BITAuthenticatorValidationTypeOnAppActive:
    case BITAuthenticatorValidationTypeOnFirstLaunch:
      //TODO tell delegate and block the application
      break;
  }
}

- (void)validationSucceeded {
  if(self.validationCompletion) {
    self.validationCompletion(YES, nil);
    self.validationCompletion = nil;
  } else {
    [self.delegate authenticatorDidValidateInstallation:self];
  }
}

#pragma mark - Private helpers
- (UIDevice *)currentDevice {
  return _currentDevice ? : [UIDevice currentDevice];;
}

- (void) cleanupInternalStorage {
  [self removeKeyFromKeychain:kBITAuthenticatorAuthTokenKey];
  [self setLastAuthenticatedVersion:nil];
}

- (void) registerObservers {
  __weak typeof(self) weakSelf = self;
  _appDidBecomeActiveObserver = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                                                  object:nil
                                                                                   queue:NSOperationQueue.mainQueue
                                                                              usingBlock:^(NSNotification *note) {
                                                                                typeof(self) strongSelf = weakSelf;
                                                                                [strongSelf applicationDidBecomeActive:note];
                                                                              }];
}

- (void) unregisterObservers {
  if(_appDidBecomeActiveObserver) {
    [[NSNotificationCenter defaultCenter] removeObserver:_appDidBecomeActiveObserver];
    _appDidBecomeActiveObserver = nil;
  }
}

#pragma mark - Property overrides
- (void)setAuthenticationToken:(NSString *)authenticationToken {
  if(![self.authenticationToken isEqualToString:authenticationToken]) {
    if(nil == authenticationToken) {
      [self removeKeyFromKeychain:kBITAuthenticatorAuthTokenKey];
    } else {
      [self addStringValueToKeychain:authenticationToken forKey:kBITAuthenticatorAuthTokenKey];
    }
  }
}

- (NSString *)authenticationToken {
  return [self stringValueFromKeychainForKey:kBITAuthenticatorAuthTokenKey];
}

- (void)setLastAuthenticatedVersion:(NSString *)lastAuthenticatedVersion {
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  if(nil == lastAuthenticatedVersion){
    [defaults removeObjectForKey:kBITAuthenticatorLastAuthenticatedVersionKey];
  } else {
    [defaults setObject:lastAuthenticatedVersion
                 forKey:kBITAuthenticatorLastAuthenticatedVersionKey];
    [defaults synchronize];
  }
}

- (NSString *)lastAuthenticatedVersion {
  return [[NSUserDefaults standardUserDefaults] objectForKey:kBITAuthenticatorLastAuthenticatedVersionKey];
}

#pragma mark - Application Lifecycle
- (void)applicationDidBecomeActive:(NSNotification *)note {
  if(BITAuthenticatorValidationTypeOnAppActive == self.validationType) {
    [self validateInstallationWithCompletion:nil];
  }
}

#pragma mark - Networking 
- (NSMutableURLRequest *) requestWithMethod:(NSString*) method
                                       path:(NSString *) path
                                 parameters:(NSDictionary *)params {
  NSParameterAssert(self.serverURL);
  NSParameterAssert(method);
  NSParameterAssert(params == nil || [method isEqualToString:@"POST"] || [method isEqualToString:@"GET"]);
  path = path ? : @"";
  
  NSURL *endpoint = [[NSURL URLWithString:self.serverURL] URLByAppendingPathComponent:path];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:endpoint];
  request.HTTPMethod = method;
  
  if (params) {
    if ([method isEqualToString:@"GET"]) {
      NSString *absoluteURLString = [endpoint absoluteString];
      //either path already has parameters, or not
      NSString *appenderFormat = [path rangeOfString:@"?"].location == NSNotFound ? @"?%@" : @"&%@";
      
      endpoint = [NSURL URLWithString:[absoluteURLString stringByAppendingFormat:appenderFormat,
                                       [self.class queryStringFromParameters:params withEncoding:NSUTF8StringEncoding]]];
      [request setURL:endpoint];
    } else {
      //TODO: this is crap. Boundary must be the same as the one in appendData
      //unify this!
      NSString *boundary = @"----FOO";
      NSString *contentType = [NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary];
      [request setValue:contentType forHTTPHeaderField:@"Content-type"];
      
      NSMutableData *postBody = [NSMutableData data];
      [params enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        [postBody appendData:[self appendPostValue:value forKey:key]];
      }];

      [postBody appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
      
      [request setHTTPBody:postBody];
    }
  }
  
  return request;
}

+ (NSString *) queryStringFromParameters:(NSDictionary *) params withEncoding:(NSStringEncoding) encoding {
  NSMutableString *queryString = [NSMutableString new];
  [params enumerateKeysAndObjectsUsingBlock:^(NSString* key, NSString* value, BOOL *stop) {
    NSAssert([key isKindOfClass:[NSString class]], @"Query parameters can only be string-string pairs");
    NSAssert([value isKindOfClass:[NSString class]], @"Query parameters can only be string-string pairs");
    
    [queryString appendFormat:queryString.length ? @"&%@=%@" : @"%@=%@", key, value];
  }];
  return queryString;
}

- (BITHTTPOperation*) operationWithURLRequest:(NSURLRequest*) request
                                   completion:(BITNetworkCompletionBlock) completion {
  BITHTTPOperation *operation = [BITHTTPOperation operationWithRequest:request
                                 ];
  [operation setCompletion:completion];
  
  return operation;
}

- (void)getPath:(NSString *)path parameters:(NSDictionary *)params completion:(BITNetworkCompletionBlock)completion {
  NSURLRequest *request = [self requestWithMethod:@"GET" path:path parameters:params];
  BITHTTPOperation *op = [self operationWithURLRequest:request
                                            completion:completion];
  [self enqeueHTTPOperation:op];
}

- (void)postPath:(NSString *)path parameters:(NSDictionary *)params completion:(BITNetworkCompletionBlock)completion {
  NSURLRequest *request = [self requestWithMethod:@"POST" path:path parameters:params];
  BITHTTPOperation *op = [self operationWithURLRequest:request
                                            completion:completion];
  [self enqeueHTTPOperation:op];
}

- (void) enqeueHTTPOperation:(BITHTTPOperation *) operation {
  [self.operationQueue addOperation:operation];
}

- (NSUInteger) cancelOperationsWithPath:(NSString*) path
                                 method:(NSString*) method {
  NSUInteger cancelledOperations = 0;
  for(BITHTTPOperation *operation in self.operationQueue.operations) {
    NSURLRequest *request = operation.URLRequest;

    BOOL matchedMethod = YES;
    if(method && ![request.HTTPMethod isEqualToString:method]) {
      matchedMethod = NO;
    }

    BOOL matchedPath = YES;
    if(path) {
      //method is not interesting here, we' just creating it to get the URL
      NSURL *url = [self requestWithMethod:@"GET" path:path parameters:nil].URL;
      matchedPath = [request.URL isEqual:url];
    }
  
    if(matchedPath && matchedMethod) {
      ++cancelledOperations;
      [operation cancel];
    }
  }
  return cancelledOperations;
}

- (NSOperationQueue *)operationQueue {
  if(nil == _operationQueue) {
    _operationQueue = [[NSOperationQueue alloc] init];
    _operationQueue.maxConcurrentOperationCount = 1;
  }
  return _operationQueue;
}

@end
