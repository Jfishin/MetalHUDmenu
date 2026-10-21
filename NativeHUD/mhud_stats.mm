// MetalHUDmenu Mac stats: live system readings inside Apple's Metal HUD.
// macOS 27+: public StateReporting API. macOS 26: the private QuartzCore label API DXMT uses.
// The stat selection is read live from MetalHUDmenu's preferences (key "systemStats").
#import <Foundation/Foundation.h>
#import <StateReporting/StateReporting.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <string>
#include "stats/telemetry.hpp"
#include "stats/power.hpp"
#include "stats/usage.hpp"

namespace {
constexpr const char *kDomain="Mac Stats";
const CFStringRef kPrefsApp=CFSTR("com.Jfishin.MetalHUDmenu");

// Keep in sync with HUDSettingsManager.systemStatCatalog.
enum Metric { CPUUsage, GPUUsage, CPUTemp, GPUTemp, Fans, SystemPower, CPUPower, GPUPower, Swap, Free, Inactive, Thermal, MetricCount };
constexpr const char *names[]={"cpuusage","gpuusage","cputemp","gputemp","fans","systempower","cpupower","gpupower","swap","free","inactive","thermal"};
constexpr const char *labels[]={"CPU usage","GPU usage","CPU temperature","GPU temperature","Fans","System power","CPU power est.","GPU power","Swap used","Free RAM","Free + inactive RAM","Thermal pressure"};
std::atomic_flag started=ATOMIC_FLAG_INIT;
dispatch_source_t timer;
bool debug=false;

// MetalHUDmenu prefs, or MHUD_SYSTEM_ELEMENTS as a test override.
void readSelection(bool enabled[MetricCount]) {
  for(int i=0;i<MetricCount;i++) enabled[i]=false;
  NSArray *list=nil;
  if(const char *env=getenv("MHUD_SYSTEM_ELEMENTS")) list=[@(env) componentsSeparatedByString:@","];
  else {
    CFPreferencesAppSynchronize(kPrefsApp);
    id value=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("systemStats"),kPrefsApp));
    if([value isKindOfClass:NSArray.class]) list=value;
  }
  for(id item in list) {
    if(![item isKindOfClass:NSString.class]) continue;
    NSString *word=[item stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    for(int i=0;i<MetricCount;i++) if([word isEqualToString:@(names[i])]) enabled[i]=true;
  }
}

NSString *fmt(const char *f,double v) { return [NSString stringWithFormat:@(f),v]; }

// One sample of the selected readings, as row label -> text.
NSDictionary<NSString*,NSString*> *sample(const bool on[MetricCount]) {
  NSMutableDictionary *out=[NSMutableDictionary dictionary];
  auto usage=[&](Metric m,hudstats::usage::Reading r) {
    out[@(labels[m])]=r.status==hudstats::usage::Status::Ready?fmt("%.1f%%",r.percent):r.status==hudstats::usage::Status::Sampling?@"Sampling...":@"Unavailable";
  };
  if(on[CPUUsage]) { static hudstats::usage::CPUSampler s; usage(CPUUsage,s.read()); }
  if(on[GPUUsage]) { static hudstats::usage::GPUSampler s; usage(GPUUsage,s.read()); }
  if(on[CPUTemp]||on[GPUTemp]) {
    auto t=hudstats::readTemperatures();
    if(on[CPUTemp]) out[@(labels[CPUTemp])]=t.cpuOK?fmt("%.1f C",t.cpuMaxC):@"Unavailable";
    if(on[GPUTemp]) out[@(labels[GPUTemp])]=t.gpuOK?fmt("%.1f C",t.gpuMaxC):@"Unavailable";
  }
  if(on[Fans]) {
    auto f=hudstats::readFans();
    if(!f.countOK) out[@"Fans"]=@"Unavailable";
    else if(f.fans.empty()) out[@"Fans"]=@"None";
    for(size_t i=0;i<f.fans.size();i++)
      out[[NSString stringWithFormat:@"Fan %zu",i+1]]=f.fans[i].actual?fmt("%.0f RPM",f.fans[i].rpm):@"Unavailable";
  }
  if(on[CPUPower]||on[GPUPower]||on[SystemPower]) {
    static hudstats::power::Sampler s;
    auto v=s.read(on[CPUPower],on[GPUPower],on[SystemPower]);
    auto watts=[&](Metric m,hudstats::power::Reading r,const char *f) {
      out[@(labels[m])]=r.status==hudstats::power::Status::Ready?fmt(f,r.watts):r.status==hudstats::power::Status::Sampling?@"Sampling...":@"Unavailable";
    };
    if(on[SystemPower]) watts(SystemPower,v.system,"%.1f W");
    if(on[CPUPower]) watts(CPUPower,v.cpu,"~%.1f W");
    if(on[GPUPower]) watts(GPUPower,v.gpu,"%.1f W");
  }
  if(on[Swap]||on[Free]||on[Inactive]) {
    auto m=hudstats::readMemory();
    if(on[Swap]) out[@(labels[Swap])]=m.swapOK?fmt("%.2f GiB",m.swapUsedBytes/1073741824.0):@"Unavailable";
    if(on[Free]) out[@(labels[Free])]=m.vmOK?fmt("%.2f GiB",m.freeBytes/1073741824.0):@"Unavailable";
    if(on[Inactive]) out[@(labels[Inactive])]=m.vmOK?fmt("%.2f GiB",(m.freeBytes+m.inactiveBytes)/1073741824.0):@"Unavailable";
  }
  if(on[Thermal]) {
    NSInteger s=NSProcessInfo.processInfo.thermalState;
    out[@(labels[Thermal])]=s>=0&&s<=3?@[@"Nominal",@"Fair",@"Serious",@"Critical"][s]:@"Unavailable";
  }
  return out;
}

// macOS 27+: Apple's HUD shows these under State Reporters, sorted by label.
API_AVAILABLE(macos(27.0)) void reportModern(NSDictionary *values) {
  static bool live=false;
  SRStateReporter *reporter=[SRStateReporter reporterForDomain:@(kDomain)];
  if(!values.count) { if(live) [reporter reportTransitionToStateLabel:nil stableMetadata:nil volatileMetadata:nil]; live=false; return; }
  if(!live) [reporter reportTransitionToStateLabel:@"Live" stableMetadata:nil volatileMetadata:values];
  else [reporter reportVolatileMetadataUpdate:values];
  live=true;
}

// macOS 26: one HUD line per stat via _CADeveloperHUDProperties (addLabel:after:, updateLabel:value:, remove:),
// the same calls DXMT makes. These methods are gone on 27, so every call is guarded.
// ponytail: untested on a macOS 26 machine; verify layout and threading there.
void reportLegacy(NSDictionary<NSString*,NSString*> *values) {
  static NSArray<NSString*> *shown=@[];
  id hud=nil;
  if(Class cls=objc_lookUpClass("_CADeveloperHUDProperties"); cls && [cls respondsToSelector:@selector(instance)])
    hud=((id(*)(id,SEL))objc_msgSend)(cls,@selector(instance));
  if(!hud||![hud respondsToSelector:@selector(addLabel:after:)]||![hud respondsToSelector:@selector(updateLabel:value:)]||![hud respondsToSelector:@selector(remove:)]) return;
  NSArray *keys=[values.allKeys sortedArrayUsingSelector:@selector(compare:)];
  NSMutableArray *ids=[NSMutableArray array];
  for(NSString *key in keys) [ids addObject:[@"MetalHUDmenu." stringByAppendingString:key]];
  if(![ids isEqualToArray:shown]) {
    for(NSString *label in shown) ((void(*)(id,SEL,id))objc_msgSend)(hud,@selector(remove:),label);
    NSString *after=@"com.apple.hud-graph.default";
    for(NSString *label in ids) { ((BOOL(*)(id,SEL,id,id))objc_msgSend)(hud,@selector(addLabel:after:),label,after); after=label; }
    shown=ids;
  }
  for(NSUInteger i=0;i<keys.count;i++)
    ((void(*)(id,SEL,id,id))objc_msgSend)(hud,@selector(updateLabel:value:),ids[i],[NSString stringWithFormat:@"%@  %@",keys[i],values[keys[i]]]);
}

void tick() { @autoreleasepool {
  bool on[MetricCount]; readSelection(on);
  NSDictionary *values=sample(on);
  if(@available(macOS 27.0,*)) reportModern(values); else reportLegacy(values);
  if(debug) fprintf(stderr,"MHUD_STATS %s\n",values.description.UTF8String);
} }

// Runs under dyld's loader lock: only look up the image name, then start the timer.
void imageAdded(const mach_header *header,intptr_t) {
  const char *name=nullptr;
  for(uint32_t i=0,n=_dyld_image_count();i<n;i++) if(_dyld_get_image_header(i)==header) { name=_dyld_get_image_name(i); break; }
  if(!name) return;
  const char *base=strrchr(name,'/'); base=base?base+1:name;
  if(strcmp(base,"libMTLHud.dylib")!=0||started.test_and_set()) return;
  timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_queue_create("MetalHUDmenu.stats",DISPATCH_QUEUE_SERIAL));
  dispatch_source_set_timer(timer,DISPATCH_TIME_NOW,NSEC_PER_SEC,NSEC_PER_SEC/10);
  dispatch_source_set_event_handler(timer,^{ tick(); });
  dispatch_resume(timer);
  if(debug) fprintf(stderr,"MHUD_STATS_STARTED %s\n",name);
}

// Append a token to a comma-separated env var unless it is already there.
void appendEnv(const char *key,const char *token) {
  const char *cur=getenv(key);
  if(!cur||!*cur) { setenv(key,token,1); return; }
  std::string list=std::string(",")+cur+",";
  if(list.find(std::string(",")+token+",")!=std::string::npos) return;
  setenv(key,(std::string(cur)+","+token).c_str(),1);
}
} // namespace

__attribute__((constructor)) static void start() {
  debug=getenv("MHUD_DEBUG")&&!strcmp(getenv("MHUD_DEBUG"),"1");
  // Adds the State Reporters section on top of the user's own HUD rows (read when Apple's HUD loads).
  if(@available(macOS 27.0,*)) {
    appendEnv("MTL_HUD_EXTRA_ELEMENTS","statereporter");
    appendEnv("MTL_HUD_STATE_REPORTER_DOMAINS",kDomain);
  }
  _dyld_register_func_for_add_image(imageAdded);
}
