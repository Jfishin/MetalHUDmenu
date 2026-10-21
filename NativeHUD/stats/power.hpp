#pragma once
// Read-only, private Apple telemetry for the verified native HUD build.
// CPU: coarse PMP cluster/SRAM histogram estimate. GPU: IOReport energy delta.
// System: independent AppleSMC PSTR float. Each source fails independently.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <set>
#include <string>
#include <vector>
#include "power_math.hpp"
#include "telemetry.hpp"

namespace hudstats::power {
enum class Status { Unavailable, Sampling, Ready };
struct Reading { Status status=Status::Unavailable; double watts=0; };
struct Values { Reading cpu,gpu,system; };

namespace detail {
using CopyGroup=CFDictionaryRef(*)(CFStringRef,CFStringRef,uint64_t,uint64_t,uint64_t);
using Subscribe=const void*(*)(const void*,CFMutableDictionaryRef,CFMutableDictionaryRef*,uint64_t,CFTypeRef);
using Sample=CFDictionaryRef(*)(const void*,CFMutableDictionaryRef,CFTypeRef);
using Delta=CFDictionaryRef(*)(CFDictionaryRef,CFDictionaryRef,CFTypeRef);
using GetString=CFStringRef(*)(CFDictionaryRef);
using GetValue=int64_t(*)(CFDictionaryRef,int32_t);
using StateCount=int32_t(*)(CFDictionaryRef);
using StateName=CFStringRef(*)(CFDictionaryRef,int32_t);
using StateResidency=int64_t(*)(CFDictionaryRef,int32_t);
struct API {
  CopyGroup copyGroup=nullptr;
  Subscribe subscribe=nullptr;
  Sample sample=nullptr;
  Delta delta=nullptr;
  GetString name=nullptr, group=nullptr, subgroup=nullptr, unit=nullptr;
  GetValue value=nullptr;
  StateCount count=nullptr;
  StateName stateName=nullptr;
  StateResidency residency=nullptr;
  bool valid() const {
    return copyGroup&&subscribe&&sample&&delta&&name&&group&&subgroup&&unit&&value&&count&&stateName&&residency;
  }
};
inline API loadAPI() {
  void *library=dlopen("/usr/lib/libIOReport.dylib",RTLD_NOW|RTLD_LOCAL);
  if(!library) return {};
  return {
    (CopyGroup)dlsym(library,"IOReportCopyChannelsInGroup"),
    (Subscribe)dlsym(library,"IOReportCreateSubscription"),
    (Sample)dlsym(library,"IOReportCreateSamples"),
    (Delta)dlsym(library,"IOReportCreateSamplesDelta"),
    (GetString)dlsym(library,"IOReportChannelGetChannelName"),
    (GetString)dlsym(library,"IOReportChannelGetGroup"),
    (GetString)dlsym(library,"IOReportChannelGetSubGroup"),
    (GetString)dlsym(library,"IOReportChannelGetUnitLabel"),
    (GetValue)dlsym(library,"IOReportSimpleGetIntegerValue"),
    (StateCount)dlsym(library,"IOReportStateGetCount"),
    (StateName)dlsym(library,"IOReportStateGetNameForIndex"),
    (StateResidency)dlsym(library,"IOReportStateGetResidency")
  };
}
inline std::string string(CFStringRef ref) {
  if(!ref) return {};
  char data[256]{};
  return CFStringGetCString(ref,data,sizeof(data),kCFStringEncodingUTF8)?data:"";
}
inline CFArrayRef channels(CFDictionaryRef dictionary) {
  if(!dictionary||CFGetTypeID(dictionary)!=CFDictionaryGetTypeID()) return nullptr;
  auto value=CFDictionaryGetValue(dictionary,CFSTR("IOReportChannels"));
  return value&&CFGetTypeID(value)==CFArrayGetTypeID()?(CFArrayRef)value:nullptr;
}
inline bool endsWith(const std::string &name,const char *suffix) {
  size_t n=strlen(suffix);
  return name.size()>=n&&name.compare(name.size()-n,n,suffix)==0;
}
inline bool cpuRail(const std::string &name) {
  size_t prefix=0;
  if(name.rfind("EACC",0)==0||name.rfind("PACC",0)==0||name.rfind("MACC",0)==0) prefix=4;
  else return false;
  size_t i=prefix;
  while(i<name.size()&&name[i]>='0'&&name[i]<='9') i++;
  return i==name.size()||name.substr(i)==" SRAM";
}
inline CFStringRef cfString(const char *text) {
  return CFStringCreateWithCString(kCFAllocatorDefault,text,kCFStringEncodingUTF8);
}
struct Meta { std::string group,name,unit; };

class Group {
  const char *groupName;
  bool cpu;
  bool attempted=false, active=false, failed=false;
  CFMutableDictionaryRef selected=nullptr;
  CFMutableDictionaryRef subscribed=nullptr;
  const void *subscription=nullptr;
  CFDictionaryRef previous=nullptr;
  std::chrono::steady_clock::time_point previousAt{};
  std::vector<Meta> metadata;
public:
  Group(const char *name,bool isCPU):groupName(name),cpu(isCPU) {}
  bool isActive() const { return active; }
  bool isFailed() const { return failed; }
  void initialize(const API &api) {
    if(attempted) return;
    attempted=true;
    CFStringRef groupString=cfString(groupName);
    CFDictionaryRef found=api.copyGroup(groupString,cpu?CFSTR("Energy"):nullptr,0,0,0);
    CFRelease(groupString);
    CFArrayRef available=channels(found);
    if(!available) { if(found) CFRelease(found); return; }
    CFMutableArrayRef chosen=CFArrayCreateMutable(kCFAllocatorDefault,0,&kCFTypeArrayCallBacks);
    std::set<std::string> seen;
    for(CFIndex i=0;i<CFArrayGetCount(available);i++) {
      auto item=(CFDictionaryRef)CFArrayGetValueAtIndex(available,i);
      std::string actualGroup=string(api.group(item));
      std::string subgroup=string(api.subgroup(item));
      std::string name=string(api.name(item));
      std::string unit=string(api.unit(item));
      bool match=cpu ? (actualGroup==groupName&&subgroup=="Energy"&&cpuRail(name))
                     : (actualGroup=="Energy Model"&&name=="GPU Energy"&&(unit=="mJ"||unit=="uJ"||unit=="nJ"));
      if(!match||!seen.insert(actualGroup+"/"+name).second) continue;
      CFArrayAppendValue(chosen,item);
      metadata.push_back({actualGroup,name,unit});
    }
    if(metadata.empty()) { CFRelease(chosen); CFRelease(found); return; }
    selected=CFDictionaryCreateMutableCopy(kCFAllocatorDefault,0,found);
    CFRelease(found);
    if(!selected) { CFRelease(chosen); failed=true; return; }
    CFDictionarySetValue(selected,CFSTR("IOReportChannels"),chosen);
    CFRelease(chosen);
    subscription=api.subscribe(nullptr,selected,&subscribed,0,nullptr);
    // Keep both descriptors for process lifetime. The returned descriptor is
    // the set actually subscribed and is used for all later samples.
    CFArrayRef subscribedItems=channels(subscribed);
    if(!subscription||!subscribedItems||CFArrayGetCount(subscribedItems)!=(CFIndex)metadata.size()) { failed=true; return; }
    for(CFIndex i=0;i<CFArrayGetCount(subscribedItems);i++) {
      auto item=(CFDictionaryRef)CFArrayGetValueAtIndex(subscribedItems,i);
      if(string(api.name(item))!=metadata[(size_t)i].name||string(api.group(item))!=metadata[(size_t)i].group) {
        failed=true; return;
      }
    }
    active=true;
  }
  Reading read(const API &api) {
    initialize(api);
    if(!active||failed) return {};
    CFDictionaryRef current=api.sample(subscription,subscribed,nullptr);
    if(!current) return {};
    auto now=std::chrono::steady_clock::now();
    if(!previous) { previous=current; previousAt=now; return {Status::Sampling,0}; }
    double elapsed=std::chrono::duration<double>(now-previousAt).count();
    if(elapsed<=0||elapsed>3.5) {
      CFRelease(previous); previous=current; previousAt=now;
      return {Status::Sampling,0};
    }
    CFDictionaryRef difference=api.delta(previous,current,nullptr);
    CFRelease(previous); previous=current; previousAt=now;
    CFArrayRef items=channels(difference);
    if(!items||CFArrayGetCount(items)!=(CFIndex)metadata.size()) {
      if(difference) CFRelease(difference);
      return {};
    }
    double sum=0;
    bool okay=true;
    for(CFIndex i=0;i<CFArrayGetCount(items);i++) {
      auto item=(CFDictionaryRef)CFArrayGetValueAtIndex(items,i);
      const auto &meta=metadata[(size_t)i];
      if(string(api.name(item))!=meta.name||string(api.group(item))!=meta.group) { okay=false; break; }
      double watts=0;
      if(cpu) {
        int32_t count=api.count(item);
        if(count<1||count>128) { okay=false; break; }
        std::vector<Bucket> buckets;
        buckets.reserve((size_t)count);
        for(int32_t j=0;j<count;j++)
          buckets.push_back({string(api.stateName(item,j)),api.residency(item,j)});
        if(!weightedWatts(buckets,watts)) { okay=false; break; }
      } else if(!energyWatts(api.value(item,0),meta.unit,elapsed,watts)) { okay=false; break; }
      sum+=watts;
    }
    CFRelease(difference);
    if(!okay||!std::isfinite(sum)||sum<=0||sum>=1000) return {};
    return {Status::Ready,sum};
  }
};

inline Reading systemPower() {
  io_service_t service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC"));
  if(!service) return {};
  io_connect_t connection=0;
  kern_return_t kr=IOServiceOpen(service,mach_task_self(),0,&connection);
  IOObjectRelease(service);
  if(kr!=KERN_SUCCESS) return {};
  constexpr uint32_t key=('P'<<24)|('S'<<16)|('T'<<8)|'R';
  static bool known=false;
  if(!known) {
    hudstats::detail::SMCParam info{};
    known=hudstats::detail::keyInfo(connection,key,info)&&info.info.size==4
      &&info.info.type==hudstats::detail::fourcc("flt ");
  }
  uint8_t bytes[32]{};
  bool ok=known&&hudstats::detail::readKey(connection,key,4,bytes);
  IOServiceClose(connection);
  if(!ok) return {};
  float watts=0; memcpy(&watts,bytes,4);
  if(!std::isfinite(watts)||watts<=0||watts>=1000) return {};
  return {Status::Ready,watts};
}
} // namespace detail

class Sampler {
  bool apiAttempted=false;
  detail::API api{};
  detail::Group cpuGroup{"PMP",true};
  detail::Group gpuGroup{"Energy Model",false};
  bool ensureAPI() {
    if(!apiAttempted) { api=detail::loadAPI(); apiAttempted=true; }
    return api.valid();
  }
public:
  Values read(bool cpu,bool gpu,bool system) {
    Values result;
    if(system) result.system=detail::systemPower();
    if(!(cpu||gpu)||!ensureAPI()) return result;
    if(cpu) {
      result.cpu=cpuGroup.read(api);
    }
    if(gpu) result.gpu=gpuGroup.read(api);
    return result;
  }
};
} // namespace hudstats::power
