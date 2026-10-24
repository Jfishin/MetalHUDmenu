// MetalHUDmenu Mac stats: live system readings inside Apple's Metal HUD.
// Rows go through Apple's private custom-metric API when the system's HUD has it (macOS 27, maybe 26);
// otherwise State Reporters on macOS 27, or the private QuartzCore label API DXMT uses on macOS 26.
// MetalHUDmenu also loads this library and calls mhud_publisher_start(): it samples for games and
// publishes the readings as notify states. Sandboxed games (App Store emulators, for example) can read
// neither its preferences nor the sensors, but can read those. Without a fresh publisher, a game
// samples by itself using the selection in MetalHUDmenu's preferences (key "systemStats").
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <os/log.h>
#include <array>
#include <initializer_list>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <dlfcn.h>
#include <fcntl.h>
#include <notify.h>
#include <sys/stat.h>
#include <unistd.h>
#include "stats/telemetry.hpp"
#include "stats/power.hpp"
#include "stats/usage.hpp"

namespace {
using hudstats::Reading;
using hudstats::Status;
constexpr const char *kDomain="Mac Stats";
const CFStringRef kPrefsApp=CFSTR("com.Jfishin.MetalHUDmenu");
const std::string kNotify="com.Jfishin.MetalHUDmenu.stats.";

// The one stat list. MetalHUDmenu shows it through mhud_catalog(), in this order.
// Tokens are stored in preferences and published names: never rename them. Apple's HUD sorts rows
// by label, so labels share a prefix ("CPU ", "GPU ", "Memory ") to keep each group together.
enum Metric { CPUUsage, CPUClock, CPUTemp, CPUPower, GPUUsage, GPUClock, GPUTemp, GPUPower, ANEUsage,
              MemPressure, Swap, Free, Inactive, SystemPower, Thermal, Fans, MetricCount };
struct Info { const char *token, *label, *group; };
constexpr Info catalog[MetricCount]={
  {"cpuusage","CPU usage","CPU"}, {"cpuclock","CPU clock","CPU"},
  {"cputemp","CPU temperature","CPU"}, {"cpupower","CPU power est.","CPU"},
  {"gpuusage","GPU usage","GPU & Neural Engine"}, {"gpuclock","GPU clock","GPU & Neural Engine"},
  {"gputemp","GPU temperature","GPU & Neural Engine"}, {"gpupower","GPU power","GPU & Neural Engine"},
  {"aneusage","ANE usage","GPU & Neural Engine"},
  {"mempressure","Memory pressure","Memory"}, {"swap","Memory swap used","Memory"},
  {"free","Memory free","Memory"}, {"inactive","Memory free+inactive","Memory"},
  {"systempower","System power","System"}, {"thermal","Thermal pressure","System"}, {"fans","Fans","System"},
};
// Rows per metric; empty means not selected. Fans and CPU clock have several.
using Rows=std::array<std::vector<Reading>,MetricCount>;

std::atomic_flag started=ATOMIC_FLAG_INIT;
dispatch_source_t timer; // a game's HUD sampler, or MetalHUDmenu's publisher (main thread starts it once)
time_t lastPing=0;       // publisher queue only
bool debug=false;

// Three bounded milestones per Wine process. NotProton does not forward MHUD_*
// diagnostics through LaunchServices, so these cannot depend on an env toggle.
// No arguments, full environment, or game data are recorded. Stop at 1 MiB.
// Diagnostics a tester can read: log stream --predicate 'subsystem == "com.Jfishin.MetalHUDmenu"'
// (stderr goes nowhere for a game opened from the Dock).
os_log_t logger() { static os_log_t log=os_log_create("com.Jfishin.MetalHUDmenu","stats"); return log; }

void wineMilestone(const char *event, NSUInteger rows=0) { @autoreleasepool {
  if(!getenv("WINEPREFIX")) return;
  NSString *directory=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/MetalHUDmenu"];
  [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
  NSString *path=[directory stringByAppendingPathComponent:@"wine.log"];
  int fd=open(path.fileSystemRepresentation,O_WRONLY|O_APPEND|O_CREAT|O_NOFOLLOW,0600);
  if(fd<0) return;
  struct stat st{};
  if(!fstat(fd,&st) && S_ISREG(st.st_mode) && st.st_uid==getuid() && st.st_size<1024*1024) {
#if defined(__arm64__)
    const char *arch="arm64";
#else
    const char *arch="x86_64";
#endif
    char line[256];
    int n=snprintf(line,sizeof(line),"time=%lld pid=%d arch=%s event=%s rows=%lu build=wine-foundation-1\n",
      (long long)time(nullptr),getpid(),arch,event,(unsigned long)rows);
    if(n>0 && n<(int)sizeof(line)) (void)write(fd,line,(size_t)n);
  }
  close(fd);
} }

bool statsEnabled() {
  CFPreferencesAppSynchronize(kPrefsApp);
  id value=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("systemStatsEnabled"),kPrefsApp));
  return ![value isKindOfClass:NSNumber.class] || [value boolValue];
}

// MetalHUDmenu prefs, or MHUD_SYSTEM_ELEMENTS as a test override.
void readSelection(bool enabled[MetricCount]) {
  for(int i=0;i<MetricCount;i++) enabled[i]=false;
  if(!statsEnabled()) return;
  NSArray *list=nil;
  if(const char *env=getenv("MHUD_SYSTEM_ELEMENTS")) list=[@(env) componentsSeparatedByString:@","];
  else {
    id value=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("systemStats"),kPrefsApp));
    if([value isKindOfClass:NSArray.class]) list=value;
  }
  for(id item in list) {
    if(![item isKindOfClass:NSString.class]) continue;
    NSString *word=[item stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    for(int i=0;i<MetricCount;i++) if([word isEqualToString:@(catalog[i].token)]) enabled[i]=true;
  }
}

// One sample of the selected readings. Samplers keep interval state, so they live for the process.
Rows measure(const bool on[MetricCount]) {
  using namespace hudstats;
  Rows rows;
  auto one=[&](Metric m,Reading r) { rows[m]={r}; };
  auto ready=[](bool ok,double value) { return ok?Reading{Status::Ready,value}:Reading{}; };
  if(on[CPUUsage]) { static usage::CPUSampler s; one(CPUUsage,s.read()); }
  if(on[CPUClock]) { static usage::CPUClockSampler s; auto c=s.read(); rows[CPUClock]={c.efficiency,c.performance}; }
  if(on[GPUUsage]||on[GPUClock]) {
    static usage::GPUSampler s;
    auto g=s.read();
    if(on[GPUUsage]) one(GPUUsage,g.usage);
    if(on[GPUClock]) one(GPUClock,g.clock);
  }
  if(on[ANEUsage]) { static usage::ANESampler s; one(ANEUsage,s.read()); }
  if(on[CPUTemp]||on[GPUTemp]) {
    auto t=readTemperatures();
    if(on[CPUTemp]) one(CPUTemp,ready(t.cpuOK,t.cpuC));
    if(on[GPUTemp]) one(GPUTemp,ready(t.gpuOK,t.gpuC));
  }
  if(on[Fans]) {
    auto f=readFans();
    if(!f.countOK) one(Fans,{});
    else if(f.fans.empty()) one(Fans,{Status::Ready,NAN}); // fanless Mac
    for(const auto &fan:f.fans) rows[Fans].push_back(ready(fan.actual,fan.rpm));
  }
  if(on[CPUPower]||on[GPUPower]||on[SystemPower]) {
    static power::Sampler s;
    auto v=s.read(on[CPUPower],on[GPUPower],on[SystemPower]);
    if(on[CPUPower]) one(CPUPower,v.cpu);
    if(on[GPUPower]) one(GPUPower,v.gpu);
    if(on[SystemPower]) one(SystemPower,v.system);
  }
  if(on[MemPressure]) {
    // Activity Monitor's numbers: the kernel's free percentage and its pressure level (1, 2 or 4).
    int freePercent=-1, level=0; size_t size=sizeof(int);
    const bool ok=sysctlbyname("kern.memorystatus_level",&freePercent,&size,nullptr,0)==0&&freePercent>=0&&freePercent<=100
      &&sysctlbyname("kern.memorystatus_vm_pressure_level",&level,&size,nullptr,0)==0;
    one(MemPressure,ready(ok,level*1000+(100-freePercent))); // one value: level in thousands, percent below
  }
  if(on[Swap]||on[Free]||on[Inactive]) {
    constexpr double GiB=1073741824.0;
    auto m=readMemory();
    if(on[Swap]) one(Swap,ready(m.swapOK,m.swapUsedBytes/GiB));
    if(on[Free]) one(Free,ready(m.vmOK,m.freeBytes/GiB));
    if(on[Inactive]) one(Inactive,ready(m.vmOK,(m.freeBytes+m.inactiveBytes)/GiB));
  }
  if(on[Thermal]) {
    NSInteger s=NSProcessInfo.processInfo.thermalState;
    one(Thermal,ready(s>=0&&s<=3,(double)s));
  }
  return rows;
}

NSString *fmt(const char *f,double v) { return [NSString stringWithFormat:@(f),v]; }

NSString *label(Metric m,size_t row,const Reading &r) {
  if(m==CPUClock) return row==0?@"CPU E-core clock":@"CPU P-core clock";
  if(m==Fans&&r.status==Status::Ready&&!std::isnan(r.value)) return [NSString stringWithFormat:@"Fan %zu",row+1];
  return @(catalog[m].label);
}

NSString *text(Metric m,const Reading &r) {
  if(r.status==Status::Sampling) return @"Sampling...";
  if(r.status!=Status::Ready) return @"Unavailable";
  switch(m) {
    case CPUUsage: case GPUUsage: case ANEUsage: return fmt("%.1f%%",r.value);
    case CPUClock: case GPUClock: return r.value>0?fmt("%.0f MHz",r.value):@"Idle";
    case CPUTemp: case GPUTemp: return fmt("%.1f C",r.value);
    case CPUPower: return fmt("~%.1f W",r.value);
    case GPUPower: case SystemPower: return fmt("%.1f W",r.value);
    case MemPressure: {
      const int level=int(r.value)/1000;
      NSString *name=level==1?@"Normal":level==2?@"Warning":level==4?@"Critical":@"Unknown";
      return [NSString stringWithFormat:@"%d%% %@",int(r.value)%1000,name];
    }
    case Swap: case Free: case Inactive: return fmt("%.2f GiB",r.value);
    case Thermal: return r.value>=0&&r.value<=3?@[@"Nominal",@"Fair",@"Serious",@"Critical"][(NSUInteger)r.value]:@"Unavailable";
    case Fans: return std::isnan(r.value)?@"None":fmt("%.0f RPM",r.value);
    case MetricCount: break;
  }
  return @"Unavailable";
}

// Row label -> text.
NSDictionary<NSString*,NSString*> *format(const Rows &rows) {
  NSMutableDictionary *out=[NSMutableDictionary dictionary];
  for(int m=0;m<MetricCount;m++)
    for(size_t i=0;i<rows[m].size();i++) out[label(Metric(m),i,rows[m][i])]=text(Metric(m),rows[m][i]);
  return out;
}

// Cross-process channel: one 64-bit notify state per value; the App Sandbox allows reading them.
// "<token>" holds the row count (0 = not selected), "<token>.<row>" the status (high 32 bits)
// and float value (low 32 bits), "stamp" the publish time. Each process uses one serial queue.
int notifyToken(const std::string &suffix) {
  static std::map<std::string,int> tokens;
  auto found=tokens.find(suffix);
  if(found!=tokens.end()) return found->second;
  int token=-1;
  if(notify_register_check((kNotify+suffix).c_str(),&token)!=NOTIFY_STATUS_OK) token=-1;
  return tokens[suffix]=token;
}
uint64_t getState(const std::string &suffix) {
  uint64_t value=0;
  const int token=notifyToken(suffix);
  if(token>=0) notify_get_state(token,&value);
  return value;
}
void setState(const std::string &suffix,uint64_t value) {
  const int token=notifyToken(suffix);
  if(token>=0) notify_set_state(token,value);
}
uint64_t pack(const Reading &r) {
  const float value=(float)r.value;
  uint32_t bits; std::memcpy(&bits,&value,4);
  return (uint64_t(r.status)<<32)|bits;
}
Reading unpack(uint64_t state) {
  const uint32_t bits=(uint32_t)state, status=(uint32_t)(state>>32);
  float value; std::memcpy(&value,&bits,4);
  return status<=uint32_t(Status::Ready)?Reading{Status(status),value}:Reading{};
}

void publish(const Rows &rows) {
  for(int m=0;m<MetricCount;m++) {
    const std::string token=catalog[m].token;
    for(size_t i=0;i<rows[m].size();i++) setState(token+"."+std::to_string(i),pack(rows[m][i]));
    setState(token,rows[m].size());
  }
  setState("stamp",(uint64_t)time(nullptr));
}

// Rows MetalHUDmenu published within the last few seconds.
bool fetch(Rows &rows) {
  const uint64_t stamp=getState("stamp"), now=(uint64_t)time(nullptr);
  if(!stamp||now<stamp||now-stamp>3) return false;
  for(int m=0;m<MetricCount;m++) {
    const std::string token=catalog[m].token;
    const uint64_t count=std::min<uint64_t>(getState(token),16);
    rows[m].clear();
    for(uint64_t i=0;i<count;i++) rows[m].push_back(unpack(getState(token+"."+std::to_string(i))));
  }
  return true;
}

// macOS 27+: Apple's HUD shows these under State Reporters, sorted by label. SRStateReporter is looked up
// at runtime, so the library also builds with SDKs that have no StateReporting framework (Xcode 26).
void reportModern(NSDictionary *values) {
  static bool live=false;
  // Do not even register a reporter when disabled from process startup.
  if(!values.count && !live) return;
  static id reporter=[]() -> id {
    dlopen("/System/Library/Frameworks/StateReporting.framework/StateReporting",RTLD_LAZY);
    Class cls=objc_lookUpClass("SRStateReporter");
    if(!cls||![cls respondsToSelector:@selector(reporterForDomain:)]) return nil;
    id instance=((id(*)(id,SEL,id))objc_msgSend)(cls,@selector(reporterForDomain:),@(kDomain));
    for(SEL selector:{@selector(reportTransitionToStateLabel:stableMetadata:volatileMetadata:),@selector(reportVolatileMetadataUpdate:)})
      if(![instance respondsToSelector:selector]) return nil;
    return instance;
  }();
  if(!reporter) return;
  auto transition=[](id label,id metadata) {
    ((void(*)(id,SEL,id,id,id))objc_msgSend)(reporter,@selector(reportTransitionToStateLabel:stableMetadata:volatileMetadata:),label,nil,metadata);
  };
  if(!values.count) { if(live) transition(nil,nil); live=false; return; }
  if(!live) transition(@"Live",values);
  else ((void(*)(id,SEL,id))objc_msgSend)(reporter,@selector(reportVolatileMetadataUpdate:),values);
  live=true;
}

// Only values with a clear good/bad range get a color; the rest stay white. Format 0xAABBGGRR.
uint32_t valueColor(Metric m,const Reading &r) {
  constexpr uint32_t White=0xFFFFFFFF, Green=0xFF58D130, Yellow=0xFF0AD6FF, Orange=0xFF0A9FFF, Red=0xFF3A45FF;
  if(r.status!=Status::Ready) return White;
  switch(m) {
    case CPUTemp: case GPUTemp: return r.value>=85?Red:r.value>=65?Yellow:Green;
    case Thermal: { constexpr uint32_t states[4]={Green,Yellow,Orange,Red}; return r.value>=0&&r.value<=3?states[int(r.value)]:White; }
    case MemPressure: { const int level=int(r.value)/1000; return level==1?Green:level==2?Yellow:level==4?Red:White; }
    default: return White;
  }
}

// Apple's private custom-metric API (MTLHUDService, the one D3DMetal and DXMT call). It draws flush,
// colored rows in our order under "Custom Metrics". Every hop is checked once; when anything is missing
// or changed, this returns nil and the rows fall back (State Reporters on macOS 27, labels on 26).
id metricService() {
  static id service=[]() -> id {
    if(getenv("MHUD_STATE_REPORTER")) return nil; // force the fallback, to check it after an OS update
    Class cls=objc_lookUpClass("MTLHUDService");
    Method insert=cls?class_getInstanceMethod(cls,@selector(insertMetric:after:name:unit:nameColor:valueColor:visualType:options:)):nullptr;
    // BOOL is "B" on arm64 and "c" on x86_64; the arguments must match exactly.
    if(!insert||strcmp(method_getTypeEncoding(insert)+1,"68@0:8@16@24@32@40I48I52I56Q60")) return nil;
    for(SEL selector:{@selector(updateLabelMetric:label:),@selector(updateMetricColor:nameColor:valueColor:),
                      @selector(removeMetric:),@selector(isHUDElementEnabled:)})
      if(![cls instancesRespondToSelector:selector]) return nil;
    if(![cls respondsToSelector:@selector(instance)]) return nil;
    id instance=((id(*)(id,SEL))objc_msgSend)(cls,@selector(instance));
    // The section only draws with the "client" element (bit 31), which start() adds.
    return instance&&((BOOL(*)(id,SEL,uint64_t))objc_msgSend)(instance,@selector(isHUDElementEnabled:),1ull<<31)?instance:nil;
  }();
  return service;
}

// False when the custom-metric API isn't usable, so the caller falls back.
bool reportColored(const Rows &rows) {
  static int warmup=2; // let Apple's HUD finish loading before asking for its service
  if(warmup>0) { warmup--; return true; }
  id service=metricService();
  if(!service) return false;
  static NSArray<NSString*> *shown=@[]; // "identifier\tname" per row, in order
  NSMutableArray<NSString*> *rowsNow=[NSMutableArray array];
  for(int m=0;m<MetricCount;m++)
    for(size_t i=0;i<rows[m].size();i++)
      [rowsNow addObject:[NSString stringWithFormat:@"MetalHUDmenu.%s.%zu\t%@",catalog[m].token,i,label(Metric(m),i,rows[m][i])]];
  if(![rowsNow isEqualToArray:shown]) {
    for(NSString *row in shown)
      ((void(*)(id,SEL,id))objc_msgSend)(service,@selector(removeMetric:),[row componentsSeparatedByString:@"\t"][0]);
    for(NSString *row in rowsNow) {
      NSArray *parts=[row componentsSeparatedByString:@"\t"]; // nil "after" appends
      ((BOOL(*)(id,SEL,id,id,id,id,uint32_t,uint32_t,uint32_t,uint64_t))objc_msgSend)(service,
        @selector(insertMetric:after:name:unit:nameColor:valueColor:visualType:options:),
        parts[0],nil,parts[1],@"",0xFFFFFFFFu,0xFFFFFFFFu,1u,0ull);
    }
    shown=rowsNow;
  }
  NSUInteger k=0;
  for(int m=0;m<MetricCount;m++)
    for(size_t i=0;i<rows[m].size();i++,k++) {
      NSString *identifier=[rowsNow[k] componentsSeparatedByString:@"\t"][0];
      ((void(*)(id,SEL,id,uint32_t,uint32_t))objc_msgSend)(service,@selector(updateMetricColor:nameColor:valueColor:),
        identifier,0xFFFFFFFFu,valueColor(Metric(m),rows[m][i]));
      ((void(*)(id,SEL,id,id))objc_msgSend)(service,@selector(updateLabelMetric:label:),identifier,text(Metric(m),rows[m][i]));
    }
  return true;
}

// macOS 26 fallback: one HUD line per stat via _CADeveloperHUDProperties (addLabel:after:, updateLabel:value:,
// remove:), the same calls DXMT makes there. Every call is guarded. These lines only show while
// MTL_HUD_ELEMENTS is unset (start() clears it when this path will be used).
// ponytail: not run on a macOS 26 machine by us; reported working there with MTL_HUD_ELEMENTS cleared.
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
  // Tell MetalHUDmenu a HUD wants readings; it publishes while these keep arriving.
  notify_post((kNotify+"client").c_str());
  Rows rows;
  const bool published=!getenv("MHUD_SYSTEM_ELEMENTS")&&fetch(rows);
  if(!published) { bool on[MetricCount]; readSelection(on); rows=measure(on); }
  NSDictionary *values=format(rows);
  const bool colored=reportColored(rows);
  const char *route="custom-metrics";
  if(!colored) {
    if(@available(macOS 27.0,*)) { reportModern(values); route="state-reporter"; }
    else { reportLegacy(values); route="labels"; }
  }
  static bool reported=false;
  if(values.count && !reported) { wineMilestone("stats-reported",values.count); reported=true; }
  static int ticks=0; // the route is settled once reportColored's warmup is over
  if(++ticks==3) os_log(logger(),"reporting %lu rows through %{public}s",(unsigned long)values.count,route);
  if(debug) fprintf(stderr,"MHUD_STATS %s %s %s\n",published?"published":"local",route,values.description.UTF8String);
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
  dispatch_source_set_event_handler(timer,^{
    static bool logged=false;
    if(!logged) { wineMilestone("apple-hud-loaded"); logged=true; }
    tick();
  });
  dispatch_resume(timer);
  if(debug) fprintf(stderr,"MHUD_STATS_STARTED %s\n",name);
}

// Whether this system's HUD has the custom-metric API, decided before Apple's HUD loads, so from its file.
// ponytail: a substring check of the library on disk; MHUD_STATE_REPORTER=1 forces the fallback.
bool customMetricsInstalled() {
  if(getenv("MHUD_STATE_REPORTER")) return false;
  const char *needle="insertMetric:after:name:unit:nameColor:valueColor:visualType:options:";
  for(NSString *path in @[@"/usr/lib/libMTLHud.dylib",@"/System/Volumes/Preboot/Cryptexes/OS/usr/lib/libMTLHud.dylib"]) {
    NSData *data=[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if(data && memmem(data.bytes,data.length,needle,strlen(needle))) return true;
  }
  return false;
}

// Append a token to a comma-separated env var unless it is already there.
void appendEnv(const char *key,const char *token) {
  const char *cur=getenv(key);
  if(!cur||!*cur) { setenv(key,token,1); return; }
  std::string list=std::string(",")+cur+",";
  if(list.find(std::string(",")+token+",")!=std::string::npos) return;
  setenv(key,(std::string(cur)+","+token).c_str(),1);
}

// A launcher started before MetalHUDmenu's last Apply (Steam, Heroic) hands its games an older copy of
// the HUD settings. Use the ones Apply saved instead. Runs before Apple's HUD reads them. Pin launches
// already pass the live settings (MHUD_HUD_EXPLICIT); sandboxed apps can't read the saved ones.
void refreshHUDEnvironment() {
  if(getenv("MHUD_HUD_EXPLICIT")) return;
  CFPreferencesAppSynchronize(kPrefsApp);
  id saved=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("appliedHUDEnvironment"),kPrefsApp));
  if(![saved isKindOfClass:NSDictionary.class]) return;
  for(id key in (NSDictionary *)saved) {
    id value=((NSDictionary *)saved)[key];
    // Only Apple's HUD settings: this path must never be able to set anything else.
    if(![key isKindOfClass:NSString.class]||![key hasPrefix:@"MTL_HUD_"]||![value isKindOfClass:NSString.class]) continue;
    if(debug) fprintf(stderr,"MHUD_STATS %s=%s (was %s)\n",[key UTF8String],[value UTF8String],getenv([key UTF8String])?:"<unset>");
    setenv([key UTF8String],[value UTF8String],1);
  }
}

bool insideMetalHUDmenu() {
  CFBundleRef bundle=CFBundleGetMainBundle();
  CFStringRef identifier=bundle?CFBundleGetIdentifier(bundle):nullptr;
  return identifier&&CFEqual(identifier,kPrefsApp);
}
} // namespace

// "token\tlabel\tgroup\n" per stat, for MetalHUDmenu's settings.
extern "C" __attribute__((visibility("default"))) const char *mhud_catalog(void) {
  static const std::string text=[] {
    std::string out;
    for(const auto &item:catalog) out+=std::string(item.token)+"\t"+item.label+"\t"+item.group+"\n";
    return out;
  }();
  return text.c_str();
}

// For MetalHUDmenu's settings: whether games here get rows through the custom-metric API (element picks
// kept) rather than macOS 26's label fallback (Apple's default elements while Mac Stats is on).
extern "C" __attribute__((visibility("default"))) bool mhud_custom_metrics(void) {
  if(@available(macOS 27.0,*)) return true; // State Reporters, the 27 fallback, keeps picks too
  return customMetricsInstalled();
}

// Called by MetalHUDmenu: samples once a second while any game's helper has pinged recently.
extern "C" __attribute__((visibility("default"))) void mhud_publisher_start(void) {
  if(timer) return;
  dispatch_queue_t queue=dispatch_queue_create("MetalHUDmenu.publisher",DISPATCH_QUEUE_SERIAL);
  int token;
  notify_register_dispatch((kNotify+"client").c_str(),&token,queue,^(int) { lastPing=time(nullptr); });
  timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,queue);
  dispatch_source_set_timer(timer,DISPATCH_TIME_NOW,NSEC_PER_SEC,NSEC_PER_SEC/10);
  dispatch_source_set_event_handler(timer,^{ @autoreleasepool {
    if(time(nullptr)-lastPing>5) return;
    bool on[MetricCount]; readSelection(on);
    publish(measure(on));
  } });
  dispatch_resume(timer);
}

__attribute__((constructor)) static void start() {
  // MetalHUDmenu loads this library only to publish and read the catalog.
  if(insideMetalHUDmenu()) return;
  debug=getenv("MHUD_DEBUG")&&!strcmp(getenv("MHUD_DEBUG"),"1");
  if(debug) fprintf(stderr,"MHUD_STATS_LOADED pid=%d\n",getpid());
  wineMilestone("helper-loaded");
  refreshHUDEnvironment();
  // Adds the Custom Metrics ("client") section on top of the user's own HUD rows (read when Apple's HUD
  // loads), plus the fallback's: State Reporters on macOS 27. On macOS 26 the fallback's labels are dropped
  // while MTL_HUD_ELEMENTS is set (it is an allow-list no element name admits them to), so it is cleared
  // only when that fallback is the one that will run: the user's element picks give way to Apple's defaults.
  if(statsEnabled()) {
    appendEnv("MTL_HUD_EXTRA_ELEMENTS","client");
    if(@available(macOS 27.0,*)) {
      appendEnv("MTL_HUD_EXTRA_ELEMENTS","statereporter");
      appendEnv("MTL_HUD_STATE_REPORTER_DOMAINS",kDomain);
    } else if(!customMetricsInstalled() && getenv("MTL_HUD_ELEMENTS")) {
      unsetenv("MTL_HUD_ELEMENTS");
      os_log(logger(),"no custom-metric API in this HUD: cleared MTL_HUD_ELEMENTS so label rows can show");
    }
  }
  os_log(logger(),"loaded in %{public}s; HUD elements %{public}s",getprogname(),getenv("MTL_HUD_ELEMENTS")?:"<Apple default>");
  _dyld_register_func_for_add_image(imageAdded);
}
