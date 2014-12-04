//
//  VZHeapInspector.m
//  VZInspector
//
//  Created by moxin.xt on 14-11-26.
//  Copyright (c) 2014年 VizLabe. All rights reserved.
//

#import "VZHeapInspector.h"
#import <malloc/malloc.h>
#import <mach/mach.h>
#import <objc/runtime.h>


typedef void (^VZHeapInspectorEnumeratorBlock)(id obj, Class clz);

typedef struct
{
    Class isa;
    
}VZ_Object;

static CFMutableSetRef vz_registeredClasses;
static NSString* vz_tracking_classPrefix;

@implementation VZHeapInspector
{
    NSMutableSet* _registeredClassSet;
}

// http://llvm.org/svn/llvm-project/lldb/tags/RELEASE_34/final/examples/darwin/heap_find/heap/heap_find.cpp
static kern_return_t
vz_task_peek (task_t task, vm_address_t remote_address, vm_size_t size, void **local_memory)
{
    *local_memory = (void*) remote_address;
    return KERN_SUCCESS;
}

static void
vz_ranges_callback (task_t task, void *context, unsigned type, vm_range_t *ptrs, unsigned count)
{
    VZHeapInspectorEnumeratorBlock block = (__bridge VZHeapInspectorEnumeratorBlock)context;
    
    for (uint64_t index = 0; index < count; index++)
    {
        vm_range_t range =  ptrs[index];
        //应该和objc_class有相同的memory layout
        VZ_Object *obj = (VZ_Object* )range.address;
        
        Class clz = NULL;
        
#ifdef __arm64__
        // See http://www.sealiesoftware.com/blog/archive/2013/09/24/objc_explain_Non-pointer_isa.html
        extern uint64_t objc_debug_isa_class_mask WEAK_IMPORT_ATTRIBUTE;
        clz = (__bridge Class)((void *)((uint64_t)obj->isa & objc_debug_isa_class_mask));
#else
        clz = obj->isa;
#endif
        
        if (CFSetContainsValue(vz_registeredClasses, (__bridge const void *)(clz)))
        {
            
            if (block) {
                block((__bridge id)(obj),clz);
            }
        }
    }
}

static inline bool vz_isTrackingObject(const char* className)
{
    bool ret = false;
    NSString* clznameStr = [NSString stringWithUTF8String:className];
    
    if ([clznameStr hasPrefix:vz_tracking_classPrefix]) {
        ret = true;
    }
    return ret;
}

+ (instancetype)sharedInstance
{
    static VZHeapInspector* instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [VZHeapInspector new];
    });
    return instance;
}

+ (void)trackObjectsWithPrefix:(NSString* )prefix
{
    vz_tracking_classPrefix = prefix;
}


+ (void)updateRegisteredClasses
{
 
    if (!vz_registeredClasses) {
        vz_registeredClasses = CFSetCreateMutable(NULL, 0, NULL);
    } else {
        CFSetRemoveAllValues(vz_registeredClasses);
    }
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
       
        Class clz = classes[i];
        CFSetAddValue(vz_registeredClasses, (__bridge const void *)(clz));
    }
    free(classes);
}

+ (void)startTrackingHeapObjects:(VZHeapInspectorEnumeratorBlock)block
{
    [self updateRegisteredClasses];

    // see https://gist.github.com/samdmarshall/17f4e66b5e2e579fd396
    vm_address_t *zones = NULL;
    unsigned int zoneCount = 0;
    kern_return_t result = malloc_get_all_zones(mach_task_self(), &vz_task_peek, &zones, &zoneCount);
    if (result == KERN_SUCCESS) {
        for (unsigned int i = 0; i < zoneCount; i++) {
            malloc_zone_t *zone = (malloc_zone_t *)zones[i];
            if (zone->introspect && zone->introspect->enumerator) {
                zone->introspect->enumerator(mach_task_self(), (__bridge void *)(block), MALLOC_PTR_IN_USE_RANGE_TYPE, zones[i], &vz_task_peek, &vz_ranges_callback);
            }
        }
    }
    
}


+ (NSSet* )livingObjects
{
    NSMutableSet* ret = [NSMutableSet set];
    [self startTrackingHeapObjects:^(id obj, __unsafe_unretained Class clz) {
        
        NSString *string = [NSString stringWithFormat:@"%@: %p",clz,obj];
        [ret addObject:string];
        
    }];
    return ret;
}

+ (NSSet* )livingObjectsWithPrefix
{
    NSMutableSet* ret = [NSMutableSet set];
    [self startTrackingHeapObjects:^(id obj, __unsafe_unretained Class clz) {
        
        const char* clzname = object_getClassName(obj);
        
        if (vz_isTrackingObject(clzname))
        {
            NSString *string = [NSString stringWithFormat:@"%@: %p",clz,obj];
            [ret addObject:string];
        }
        
    }];
    
    return ret;
}

@end
