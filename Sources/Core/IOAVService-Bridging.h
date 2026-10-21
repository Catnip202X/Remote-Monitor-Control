//
//  IOAVService-Bridging.h
//  Remote Monitor Control
//
//  Private IOKit functions used on Apple Silicon Macs to talk to an external
//  display's DDC/CI channel over I2C. These are the same calls used by
//  MonitorControl, m1ddc, BetterDisplay & co. They are exported by IOKit.framework.
//

#ifndef IOAVService_Bridging_h
#define IOAVService_Bridging_h

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

typedef CFTypeRef IOAVService;

extern IOAVService _Nullable IOAVServiceCreateWithService(CFAllocatorRef _Nullable allocator,
                                                             io_service_t service) CF_RETURNS_RETAINED;

extern IOReturn IOAVServiceReadI2C(IOAVService _Nonnull service,
                                   uint32_t chipAddress,
                                   uint32_t offset,
                                   void * _Nonnull outputBuffer,
                                   uint32_t outputBufferSize);

extern IOReturn IOAVServiceWriteI2C(IOAVService _Nonnull service,
                                    uint32_t chipAddress,
                                    uint32_t dataAddress,
                                    void * _Nonnull inputBuffer,
                                    uint32_t inputBufferSize);

#endif /* IOAVService_Bridging_h */
