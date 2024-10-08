/*
 * Copyright 2019 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "Public/GULCCComponentContainer.h"

#import "Public/GULCCComponent.h"
#import "Public/GULCCLibrary.h"

#import <GoogleUtilities/GULLogger.h>

// Logger levels
#import <GoogleUtilities/GULLoggerLevel.h>

static NSString *kGULComponentSubsystem = @"com.google.googleutilitiescomponents";
static NSString *kGULComponentContainer = @"[GoogleUtilitiesComponents]";

NS_ASSUME_NONNULL_BEGIN

@interface GULCCComponentContainer ()

/// The dictionary of components that are registered for a particular app. The key is an `NSString`
/// of the protocol.
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, GULCCComponentCreationBlock> *components;

/// Cached instances of components that requested to be cached.
@property(nonatomic, strong) NSMutableDictionary<NSString *, id> *cachedInstances;

/// Protocols of components that have requested to be eagerly instantiated.
@property(nonatomic, strong, nullable) NSMutableArray<Protocol *> *eagerProtocolsToInstantiate;

@end

@implementation GULCCComponentContainer

// Collection of all classes that register to provide components.
static NSMutableSet<Class> *sGULComponentRegistrants;

#pragma mark - Public Registration

+ (void)registerAsComponentRegistrant:(Class<GULCCLibrary>)klass {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sGULComponentRegistrants = [[NSMutableSet<Class> alloc] init];
  });

  [self registerAsComponentRegistrant:klass inSet:sGULComponentRegistrants];
}

+ (void)registerAsComponentRegistrant:(Class<GULCCLibrary>)klass
                                inSet:(NSMutableSet<Class> *)allRegistrants {
  [allRegistrants addObject:klass];
}

#pragma mark - Internal Initialization

- (instancetype)initWithContext:(nullable id)context {
  return [self initWithContext:context registrants:sGULComponentRegistrants];
}

- (instancetype)initWithContext:(nullable id)context
                    registrants:(NSMutableSet<Class> *)allRegistrants {
  self = [super init];
  if (self) {
    _context = context;
    _cachedInstances = [NSMutableDictionary<NSString *, id> dictionary];
    _components = [NSMutableDictionary<NSString *, GULCCComponentCreationBlock> dictionary];

    [self populateComponentsFromRegisteredClasses:allRegistrants withContext:context];
  }
  return self;
}

- (void)populateComponentsFromRegisteredClasses:(NSSet<Class> *)classes withContext:(id)context {
  // Keep track of any components that need to eagerly instantiate after all components are added.
  self.eagerProtocolsToInstantiate = [[NSMutableArray alloc] init];

  // Loop through the verified component registrants and populate the components array.
  for (Class<GULCCLibrary> klass in classes) {
    // Loop through all the components being registered and store them as appropriate.
    // Classes which do not provide functionality should use a dummy GULCCComponentRegistrant
    // protocol.
    for (GULCCComponent *component in [klass componentsToRegister]) {
      // Check if the component has been registered before, and error out if so.
      NSString *protocolName = NSStringFromProtocol(component.protocol);
      if (self.components[protocolName]) {
        GULOSLogError(kGULComponentSubsystem, kGULComponentContainer, NO, @"I-COM000001",
                      @"Attempted to register protocol %@, but it already has an implementation.",
                      protocolName);
        continue;
      }

      // Store the creation block for later usage.
      self.components[protocolName] = component.creationBlock;

      // Queue any protocols that should be eagerly instantiated. Don't instantiate them yet
      // because they could depend on other components that haven't been added to the components
      // array yet.
      if (component.instantiationTiming == GULCCInstantiationTimingAlwaysEager) {
        [self.eagerProtocolsToInstantiate addObject:component.protocol];
      }
    }
  }
}

#pragma mark - Instance Creation

- (void)instantiateEagerComponents {
  // After all components are registered, instantiate the ones that are requesting eager
  // instantiation.
  @synchronized(self) {
    for (Protocol *protocol in self.eagerProtocolsToInstantiate) {
      // Get an instance for the protocol, which will instantiate it since it couldn't have been
      // cached yet. Ignore the instance coming back since we don't need it.
      __unused id unusedInstance = [self instanceForProtocol:protocol];
    }

    // All eager instantiation is complete, clear the stored property now.
    self.eagerProtocolsToInstantiate = nil;
  }
}

/// Instantiate an instance of a class that conforms to the specified protocol.
/// This will:
///   - Call the block to create an instance if possible,
///   - Validate that the instance returned conforms to the protocol it claims to,
///   - Cache the instance if the block requests it
///
/// Note that this method assumes the caller already has @synchronized on self.
- (nullable id)instantiateInstanceForProtocol:(Protocol *)protocol
                                    withBlock:(GULCCComponentCreationBlock)creationBlock {
  if (!creationBlock) {
    return nil;
  }

  // Create an instance using the creation block.
  BOOL shouldCache = NO;
  id instance = creationBlock(self, &shouldCache);
  if (!instance) {
    return nil;
  }

  // An instance was created, validate that it conforms to the protocol it claims to.
  NSString *protocolName = NSStringFromProtocol(protocol);
  if (![instance conformsToProtocol:protocol]) {
    GULOSLogError(kGULComponentSubsystem, kGULComponentContainer, NO, @"I-COM000002",
                  @"An instance conforming to %@ was requested, but the instance provided does not "
                  @"conform to the protocol",
                  protocolName);
  }

  // The instance is ready to be returned, but check if it should be cached first before returning.
  if (shouldCache) {
    self.cachedInstances[protocolName] = instance;
  }

  return instance;
}

#pragma mark - Internal Retrieval

- (nullable id)instanceForProtocol:(Protocol *)protocol {
  // Check if there is a cached instance, and return it if so.
  NSString *protocolName = NSStringFromProtocol(protocol);

  id cachedInstance;
  @synchronized(self) {
    cachedInstance = self.cachedInstances[protocolName];
    if (!cachedInstance) {
      // Use the creation block to instantiate an instance and return it.
      GULCCComponentCreationBlock creationBlock = self.components[protocolName];
      cachedInstance = [self instantiateInstanceForProtocol:protocol withBlock:creationBlock];
    }
  }
  return cachedInstance;
}

#pragma mark - Lifecycle

- (void)removeAllCachedInstances {
  @synchronized(self) {
    // Loop through the cache and notify each instance that is a maintainer to clean up after
    // itself.
    for (id instance in self.cachedInstances.allValues) {
      if ([instance conformsToProtocol:@protocol(GULCCComponentLifecycleMaintainer)] &&
          [instance respondsToSelector:@selector(containerWillBeEmptied:)]) {
        [instance containerWillBeEmptied:self];
      }
    }

    // Empty the cache.
    [self.cachedInstances removeAllObjects];
  }
}

@end

NS_ASSUME_NONNULL_END
