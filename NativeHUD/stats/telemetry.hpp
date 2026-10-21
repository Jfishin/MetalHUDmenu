#pragma once
// Minimal read-only Apple Silicon memory/swap/temperature sampling helpers.
// Temperature access uses undocumented AppleSMC user-client protocol; treat all
// readings as optional and validate on each supported hardware/OS combination.
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/vm_statistics.h>
#include <sys/sysctl.h>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <cerrno>
#include <cmath>

namespace hudstats {
struct MemorySample {
  uint64_t physicalBytes=0, freeBytes=0, inactiveBytes=0, purgeableBytes=0;
  uint64_t swapUsedBytes=0, swapTotalBytes=0;
  bool vmOK=false, swapOK=false;
};
inline MemorySample readMemory() {
  MemorySample s; vm_size_t page=0;
  if (host_page_size(mach_host_self(), &page)!=KERN_SUCCESS) return s;
  size_t n=sizeof(s.physicalBytes);
  s.physicalBytes = sysctlbyname("hw.memsize", &s.physicalBytes, &n, nullptr, 0)==0 ? s.physicalBytes : 0;
  vm_statistics64_data_t vm{}; mach_msg_type_number_t count=HOST_VM_INFO64_COUNT;
  if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &count)==KERN_SUCCESS) {
    s.vmOK=true; s.freeBytes=(uint64_t)vm.free_count*page;
    s.inactiveBytes=(uint64_t)vm.inactive_count*page;
    s.purgeableBytes=(uint64_t)vm.purgeable_count*page;
  }
  xsw_usage sw{}; n=sizeof(sw);
  if (sysctlbyname("vm.swapusage", &sw, &n, nullptr, 0)==0) {
    s.swapOK=true; s.swapUsedBytes=sw.xsu_used; s.swapTotalBytes=sw.xsu_total;
  }
  return s;
}
struct TemperatureSensor { std::string key; float celsius; };
struct TemperatureSample {
  std::vector<TemperatureSensor> cpu, gpu;
  float cpuMeanC=0, cpuMaxC=0, gpuMeanC=0, gpuMaxC=0;
  bool cpuOK=false, gpuOK=false;
};
namespace detail {
struct SMCVersion { uint8_t major,minor,build,reserved; uint16_t release; };
struct SMCPLimitData { uint16_t version,length; uint32_t cpu,gpu,mem; };
struct SMCKeyInfo { uint32_t size,type; uint8_t attrs; };
struct SMCParam { uint32_t key; SMCVersion ver; SMCPLimitData limit; SMCKeyInfo info; uint8_t result,status,cmd; uint32_t data32; uint8_t bytes[32]; };
static_assert(sizeof(SMCParam)==80,"AppleSMC parameter ABI changed");
inline uint32_t fourcc(const char*s) { return (uint32_t(uint8_t(s[0]))<<24)|(uint32_t(uint8_t(s[1]))<<16)|(uint32_t(uint8_t(s[2]))<<8)|uint8_t(s[3]); }
inline std::string name(uint32_t k) { char b[5]={(char)(k>>24),(char)(k>>16),(char)(k>>8),(char)k,0}; return b; }
inline bool call(io_connect_t c, SMCParam &in, SMCParam &out) { size_t n=sizeof(out); std::memset(&out,0,sizeof(out)); return IOConnectCallStructMethod(c,2,&in,sizeof(in),&out,&n)==KERN_SUCCESS && out.result==0; }
inline bool keyInfo(io_connect_t c,uint32_t key,SMCParam &out) { SMCParam in{}; in.key=key; in.cmd=9; return call(c,in,out); }
inline bool readKey(io_connect_t c,uint32_t key,uint32_t size,uint8_t bytes[32]) { SMCParam in{}; in.key=key; in.info.size=size; in.cmd=5; SMCParam out{}; if(!call(c,in,out)) return false; std::memcpy(bytes,out.bytes,32); return true; }
}
struct FanReading { std::string key, keyType; double rpm=0; bool actual=false; };
struct FanSample { std::vector<FanReading> fans; bool countOK=false; };
inline FanSample readFans() {
  FanSample sample;
  io_service_t service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC"));
  if(!service) return sample;
  io_connect_t c=0; kern_return_t kr=IOServiceOpen(service,mach_task_self(),0,&c); IOObjectRelease(service);
  if(kr!=KERN_SUCCESS) return sample;
  auto readCount=[&](const char *key,uint32_t &value)->bool {
    detail::SMCParam info{}; const uint32_t k=detail::fourcc(key);
    if(!detail::keyInfo(c,k,info) || info.info.size==0 || info.info.size>4) return false;
    uint8_t b[32]{}; if(!detail::readKey(c,k,info.info.size,b)) return false;
    if(info.info.size==1) value=b[0];
    else if(info.info.size==2) value=(uint32_t(b[0])<<8)|b[1];
    else if(info.info.size==4) value=(uint32_t(b[0])<<24)|(uint32_t(b[1])<<16)|(uint32_t(b[2])<<8)|b[3];
    else return false;
    return true;
  };
  uint32_t count=0;
  bool countOK=readCount("FNum",count);
  if(!countOK) countOK=readCount("#FAN",count);
  if(countOK && count<=10) {
    sample.countOK=true;
    for(uint32_t i=0;i<count;i++) {
      // AppleSMC F%dAc is the current measured RPM; F%dTg is target RPM.
      char key[5]={'F',char('0'+i),'A','c',0};
      const uint32_t kc=detail::fourcc(key); detail::SMCParam info{};
      FanReading reading{key,"",0,false};
      if(!detail::keyInfo(c,kc,info) || info.info.size==0 || info.info.size>4) { sample.fans.push_back(reading); continue; }
      const uint32_t t=info.info.type; char type[5]={(char)(t>>24),(char)(t>>16),(char)(t>>8),(char)t,0};
      reading.keyType=type;
      uint8_t b[32]{}; if(!detail::readKey(c,kc,info.info.size,b)) { sample.fans.push_back(reading); continue; }
      double rpm=0;
      if(!std::strcmp(type,"fpe2") && info.info.size==2) rpm=((uint32_t(b[0])<<8)|b[1])/4.0;
      else if(!std::strcmp(type,"flt ") && info.info.size==4) { float v; std::memcpy(&v,b,4); rpm=v; }
      else if(!std::strcmp(type,"ui16") && info.info.size==2) rpm=(uint32_t(b[0])<<8)|b[1];
      else { sample.fans.push_back(reading); continue; }
      if(std::isfinite(rpm) && rpm>=0 && rpm<=20000) { reading.rpm=rpm; reading.actual=true; }
      sample.fans.push_back(reading);
    }
  }
  IOServiceClose(c); return sample;
}

inline TemperatureSample readTemperatures() {
  TemperatureSample s;
  io_service_t service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC"));
  if(!service) return s; io_connect_t c=0; kern_return_t kr=IOServiceOpen(service,mach_task_self(),0,&c); IOObjectRelease(service);
  if(kr!=KERN_SUCCESS) return s;
  // Discover once per process. The caller owns serialization.
  static std::vector<std::pair<uint32_t,bool>> candidates;
  static bool discovered=false;
  if(!discovered) {
  detail::SMCParam inf{}; uint32_t count=0;
  if(detail::keyInfo(c,detail::fourcc("#KEY"),inf) && inf.info.size==4 && detail::readKey(c,detail::fourcc("#KEY"),4,inf.bytes))
    count=(uint32_t(inf.bytes[0])<<24)|(uint32_t(inf.bytes[1])<<16)|(uint32_t(inf.bytes[2])<<8)|inf.bytes[3];
  if(count>0 && count<10000) {
  for(uint32_t i=0;i<count;i++) {
    detail::SMCParam idx{}; idx.cmd=8; idx.data32=i; detail::SMCParam keyOut{};
    if(!detail::call(c,idx,keyOut)) continue;
    const std::string key=detail::name(keyOut.key);
    const bool isCPU=key.rfind("Tp",0)==0 || key.rfind("Te",0)==0;
    const bool isGPU=key.rfind("Tg",0)==0;
    if(!isCPU && !isGPU) continue;
    detail::SMCParam info{}; if(!detail::keyInfo(c,keyOut.key,info) || info.info.size!=4 || info.info.type!=detail::fourcc("flt ")) continue;
    candidates.push_back({keyOut.key,isCPU});
  }
  discovered=true;
  }
  }
  for(const auto& candidate:candidates) {
    uint8_t b[32]{};if(!detail::readKey(c,candidate.first,4,b))continue;
    float v;std::memcpy(&v,b,4);if(!std::isfinite(v)||v<10||v>120)continue;
    (candidate.second?s.cpu:s.gpu).push_back({detail::name(candidate.first),v});
  }
  IOServiceClose(c);
  auto summarize=[](const std::vector<TemperatureSensor>&xs,float&mean,float&max){ if(xs.empty())return; float sum=0;max=xs.front().celsius;for(const auto&x:xs){sum+=x.celsius;if(x.celsius>max)max=x.celsius;}mean=sum/xs.size();};
  summarize(s.cpu,s.cpuMeanC,s.cpuMaxC); summarize(s.gpu,s.gpuMeanC,s.gpuMaxC);
  s.cpuOK=!s.cpu.empty(); s.gpuOK=!s.gpu.empty(); return s;
}
} // namespace hudstats
