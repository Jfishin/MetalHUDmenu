#pragma once
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <algorithm>
#include <chrono>
#include <utility>
#include "usage_math.hpp"
#include "power.hpp"

namespace hudstats::usage {

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

// pmgr "voltage-statesN": little-endian (frequency, voltage) uint32 pairs, returned in MHz.
// M4 CPU tables are kHz; GPU and older CPU tables are Hz.
inline std::vector<double> frequencyTable(const char *key) {
  std::vector<double> mhz;
  io_iterator_t iterator=IO_OBJECT_NULL;
  if(IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("AppleARMIODevice"),&iterator)!=KERN_SUCCESS) return mhz;
  for(io_object_t entry;(entry=IOIteratorNext(iterator));IOObjectRelease(entry)) {
    io_name_t name{};
    if(!mhz.empty()||IORegistryEntryGetName(entry,name)!=KERN_SUCCESS||std::strcmp(name,"pmgr")) continue;
    CFStringRef property=power::detail::cfString(key);
    CFTypeRef value=IORegistryEntryCreateCFProperty(entry,property,kCFAllocatorDefault,0);
    CFRelease(property);
    if(value&&CFGetTypeID(value)==CFDataGetTypeID()) {
      const uint8_t *bytes=CFDataGetBytePtr((CFDataRef)value);
      std::vector<uint32_t> raw((size_t)CFDataGetLength((CFDataRef)value)/8);
      for(size_t i=0;i<raw.size();i++) std::memcpy(&raw[i],bytes+i*8,4);
      const uint32_t peak=raw.empty()?0:*std::max_element(raw.begin(),raw.end());
      const double scale=peak>=100000000?1e6:1e3;
      for(uint32_t frequency:raw) mhz.push_back(frequency/scale);
    }
    if(value) CFRelease(value);
  }
  IOObjectRelease(iterator);
  return mhz;
}

// One IOReport state-residency subscription over the channels `keep` accepts.
// read() returns each channel's states since the previous read.
class Residency {
public:
  using Keep=bool(*)(const std::string &subgroup,const std::string &name);
  using Channels=std::vector<std::pair<std::string,std::vector<State>>>;
private:
  const char *group,*subgroup;
  Keep keep;
  bool attempted=false;
  power::detail::API api{};
  const void *subscription=nullptr;
  CFMutableDictionaryRef selected=nullptr;
  CFDictionaryRef previous=nullptr;
  std::chrono::steady_clock::time_point previousAt{};

  bool accepts(CFDictionaryRef item) const {
    using power::detail::string;
    const std::string sub=string(api.subgroup(item));
    return string(api.group(item))==group&&(!subgroup||sub==subgroup)&&keep(sub,string(api.name(item)));
  }
  void initialize() {
    if(attempted) return;
    attempted=true;
    api=power::detail::loadAPI();
    if(!api.valid()) return;
    CFStringRef groupString=power::detail::cfString(group);
    CFStringRef subgroupString=subgroup?power::detail::cfString(subgroup):nullptr;
    CFDictionaryRef found=api.copyGroup(groupString,subgroupString,0,0,0);
    CFRelease(groupString);
    if(subgroupString) CFRelease(subgroupString);
    CFArrayRef available=power::detail::channels(found);
    if(!available) { if(found) CFRelease(found); return; }
    CFMutableArrayRef chosen=CFArrayCreateMutable(kCFAllocatorDefault,0,&kCFTypeArrayCallBacks);
    for(CFIndex i=0;i<CFArrayGetCount(available);i++) {
      auto item=(CFDictionaryRef)CFArrayGetValueAtIndex(available,i);
      if(CFGetTypeID(item)==CFDictionaryGetTypeID()&&accepts(item)) CFArrayAppendValue(chosen,item);
    }
    const CFIndex count=CFArrayGetCount(chosen);
    CFMutableDictionaryRef requested=count?CFDictionaryCreateMutableCopy(kCFAllocatorDefault,0,found):nullptr;
    CFRelease(found);
    if(requested) CFDictionarySetValue(requested,CFSTR("IOReportChannels"),chosen);
    CFRelease(chosen);
    if(!requested) return;
    const void *candidate=api.subscribe(nullptr,requested,&selected,0,nullptr);
    CFRelease(requested);
    // The subscription and its descriptor are bounded process-lifetime objects.
    CFArrayRef subscribed=power::detail::channels(selected);
    if(candidate&&subscribed&&CFArrayGetCount(subscribed)==count) subscription=candidate;
  }
public:
  Residency(const char *groupName,const char *subgroupName,Keep accept):group(groupName),subgroup(subgroupName),keep(accept) {}
  Status read(Channels &out) {
    out.clear();
    initialize();
    if(!subscription) return Status::Unavailable;
    CFDictionaryRef current=api.sample(subscription,selected,nullptr);
    if(!current) { if(previous) CFRelease(previous); previous=nullptr; return Status::Unavailable; }
    const auto now=std::chrono::steady_clock::now();
    const double elapsed=std::chrono::duration<double>(now-previousAt).count();
    CFDictionaryRef before=previous;
    previous=current; previousAt=now;
    if(!before||elapsed<=0||elapsed>3.5) { if(before) CFRelease(before); return Status::Sampling; }
    CFDictionaryRef difference=api.delta(before,current,nullptr);
    CFRelease(before);
    CFArrayRef items=power::detail::channels(difference);
    for(CFIndex i=0;items&&i<CFArrayGetCount(items);i++) {
      auto item=(CFDictionaryRef)CFArrayGetValueAtIndex(items,i);
      if(CFGetTypeID(item)!=CFDictionaryGetTypeID()||!accepts(item)) continue;
      const int32_t count=api.count(item);
      if(count<=0||count>128) continue;
      std::vector<State> states;
      for(int32_t j=0;j<count;j++) states.push_back({power::detail::string(api.stateName(item,j)),api.residency(item,j)});
      out.push_back({power::detail::string(api.name(item)),std::move(states)});
    }
    if(difference) CFRelease(difference);
    return out.empty()?Status::Unavailable:Status::Ready;
  }
};

// GPUPH records device-wide time in idle/off and active performance states.
// Usage is active time, like mactop. macmon's default view instead scales it by clock / max clock,
// so it reads far lower while a game keeps the GPU at low clocks.
struct GPUReading { Reading usage, clock; };
class GPUSampler {
  Residency residency{"GPU Stats","GPU Performance States",
    [](const std::string&,const std::string &name) { return name=="GPUPH"; }};
  std::vector<double> table=frequencyTable("voltage-states9");
public:
  GPUReading read() {
    Residency::Channels channels;
    const Status status=residency.read(channels);
    if(status!=Status::Ready) return {{status,0},{status,0}};
    // Multiple GPUPH channels would require a verified multi-GPU policy.
    if(channels.size()!=1) return {};
    GPUReading reading;
    double value=0;
    if(gpuActivePercent(channels[0].second,value)) reading.usage={Status::Ready,value};
    if(!table.empty()&&activeClock(channels[0].second,table,value)) reading.clock={Status::Ready,value};
    return reading;
  }
};

// Cluster clocks from "ECPU", "PCPU", "PCPU1"... DVFS residency. Clusters of one kind share a table,
// so they are weighted together: an idle cluster does not drag down a busy one.
struct CPUClocks { Reading efficiency, performance; };
class CPUClockSampler {
  Residency residency{"CPU Stats","CPU Complex Performance States",
    [](const std::string&,const std::string &name) { return name.rfind("ECPU",0)==0||name.rfind("PCPU",0)==0; }};
  std::vector<double> efficiency=frequencyTable("voltage-states1-sram");
  std::vector<double> performance=frequencyTable("voltage-states5-sram");
  static Reading clock(const Residency::Channels &channels,char kind,const std::vector<double> &table) {
    std::vector<State> merged;
    for(const auto &channel:channels)
      if(channel.first[0]==kind) merged.insert(merged.end(),channel.second.begin(),channel.second.end());
    double mhz=0;
    if(merged.empty()||table.empty()||!activeClock(merged,table,mhz)) return {};
    return {Status::Ready,mhz};
  }
public:
  CPUClocks read() {
    Residency::Channels channels;
    const Status status=residency.read(channels);
    if(status!=Status::Ready) return {{status,0},{status,0}};
    return {clock(channels,'E',efficiency),clock(channels,'P',performance)};
  }
};

// ANE usage: the highest raised-floor share across the ANE's PMP floor channels
// ("ANE-SLOW-AF-BW", "ANE0", ...). Its Energy Model counter reads 0 on macOS 27 even under load.
class ANESampler {
  Residency residency{"PMP",nullptr,[](const std::string &subgroup,const std::string &name) {
    return name.rfind("ANE",0)==0&&subgroup.find("Floor")!=std::string::npos; }};
public:
  Reading read() {
    Residency::Channels channels;
    const Status status=residency.read(channels);
    if(status!=Status::Ready) return {status,0};
    Reading result;
    double value=0;
    for(const auto &channel:channels)
      if(raisedFloorPercent(channel.second,value)&&(result.status!=Status::Ready||value>result.value)) result={Status::Ready,value};
    return result;
  }
};

}
