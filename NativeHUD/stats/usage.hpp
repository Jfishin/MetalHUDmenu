#pragma once
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <chrono>
#include "usage_math.hpp"
#include "power.hpp"

namespace hudstats::usage {
enum class Status { Unavailable, Sampling, Ready };
struct Reading { Status status=Status::Unavailable; double percent=0; };

class CPUSampler {
  bool hasPrevious=false;
  CPUTicks previous{};
  std::chrono::steady_clock::time_point previousAt{};
public:
  Reading read() {
    host_cpu_load_info_data_t data{};
    mach_msg_type_number_t count=HOST_CPU_LOAD_INFO_COUNT;
    const mach_port_t host=mach_host_self();
    kern_return_t status=host_statistics(host,HOST_CPU_LOAD_INFO,(host_info_t)&data,&count);
    mach_port_deallocate(mach_task_self(),host);
    if(status!=KERN_SUCCESS||count<HOST_CPU_LOAD_INFO_COUNT) { hasPrevious=false; return {}; }
    const CPUTicks current{data.cpu_ticks[CPU_STATE_USER],data.cpu_ticks[CPU_STATE_SYSTEM],
                           data.cpu_ticks[CPU_STATE_IDLE],data.cpu_ticks[CPU_STATE_NICE]};
    const auto now=std::chrono::steady_clock::now();
    const double elapsed=std::chrono::duration<double>(now-previousAt).count();
    double percent=0;
    Reading reading;
    if(!hasPrevious||elapsed<=0||elapsed>3.5) reading={Status::Sampling,0};
    else if(totalCPUPercent(previous,current,percent)) reading={Status::Ready,percent};
    previous=current;
    previousAt=now;
    hasPrevious=true;
    return reading;
  }
};

// GPUPH records device-wide time in idle/off and active performance states.
// This is active-time utilization, not frequency weighting or shader occupancy.
class GPUSampler {
  bool attempted=false;
  power::detail::API api{};
  const void *subscription=nullptr;
  CFMutableDictionaryRef selected=nullptr;
  CFDictionaryRef previous=nullptr;
  std::chrono::steady_clock::time_point previousAt{};

  static bool target(const power::detail::API &functions,CFDictionaryRef item) {
    using power::detail::string;
    return string(functions.group(item))=="GPU Stats"
        &&string(functions.subgroup(item))=="GPU Performance States"
        &&string(functions.name(item))=="GPUPH";
  }
  void initialize() {
    if(attempted) return;
    attempted=true;
    api=power::detail::loadAPI();
    if(!api.valid()) return;
    CFDictionaryRef found=api.copyGroup(CFSTR("GPU Stats"),CFSTR("GPU Performance States"),0,0,0);
    CFArrayRef channels=power::detail::channels(found);
    if(!channels) { if(found) CFRelease(found); return; }
    CFMutableArrayRef chosen=CFArrayCreateMutable(kCFAllocatorDefault,0,&kCFTypeArrayCallBacks);
    if(!chosen) { CFRelease(found); return; }
    for(CFIndex i=0;i<CFArrayGetCount(channels);i++) {
      auto item=(CFDictionaryRef)CFArrayGetValueAtIndex(channels,i);
      if(CFGetTypeID(item)==CFDictionaryGetTypeID()&&target(api,item)) CFArrayAppendValue(chosen,item);
    }
    // Multiple identical channels would require a verified multi-GPU policy.
    if(CFArrayGetCount(chosen)!=1) { CFRelease(chosen); CFRelease(found); return; }
    CFMutableDictionaryRef requested=CFDictionaryCreateMutableCopy(kCFAllocatorDefault,0,found);
    CFRelease(found);
    if(!requested) { CFRelease(chosen); return; }
    CFDictionarySetValue(requested,CFSTR("IOReportChannels"),chosen);
    CFRelease(chosen);
    const void *candidate=api.subscribe(nullptr,requested,&selected,0,nullptr);
    CFRelease(requested);
    channels=power::detail::channels(selected);
    if(!candidate||!channels||CFArrayGetCount(channels)!=1) return;
    auto item=(CFDictionaryRef)CFArrayGetValueAtIndex(channels,0);
    if(CFGetTypeID(item)!=CFDictionaryGetTypeID()||!target(api,item)) return;
    // The subscription and its descriptor are bounded process-lifetime objects.
    subscription=candidate;
  }
public:
  Reading read() {
    initialize();
    if(!subscription) return {};
    CFDictionaryRef current=api.sample(subscription,selected,nullptr);
    if(!current) { if(previous) CFRelease(previous); previous=nullptr; return {}; }
    const auto now=std::chrono::steady_clock::now();
    const double elapsed=std::chrono::duration<double>(now-previousAt).count();
    if(!previous||elapsed<=0||elapsed>3.5) {
      if(previous) CFRelease(previous);
      previous=current; previousAt=now;
      return {Status::Sampling,0};
    }
    CFDictionaryRef difference=api.delta(previous,current,nullptr);
    CFRelease(previous); previous=current; previousAt=now;
    CFArrayRef channels=power::detail::channels(difference);
    double percent=0;
    bool valid=false;
    if(channels&&CFArrayGetCount(channels)==1) {
      auto item=(CFDictionaryRef)CFArrayGetValueAtIndex(channels,0);
      if(CFGetTypeID(item)==CFDictionaryGetTypeID()&&target(api,item)) {
        const int32_t count=api.count(item);
        if(count>0&&count<=128) {
          std::vector<GPUState> states;
          for(int32_t i=0;i<count;i++) states.push_back({power::detail::string(api.stateName(item,i)),api.residency(item,i)});
          valid=gpuActivePercent(states,percent);
        }
      }
    }
    if(difference) CFRelease(difference);
    return valid?Reading{Status::Ready,percent}:Reading{};
  }
};

}
