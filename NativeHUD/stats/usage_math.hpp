#pragma once
#include <cstdint>
#include <string>
#include <vector>
#include <set>

namespace hudstats::usage {
struct CPUTicks { uint32_t user=0, system=0, idle=0, nice=0; };

// HOST_CPU_LOAD_INFO aggregates tick counts across every CPU. Dividing by the
// total tick delta already normalizes the machine to 0–100%, including on
// heterogeneous Apple silicon; no per-core multiplier is applied.
inline bool totalCPUPercent(const CPUTicks &before,const CPUTicks &after,double &percent) {
  const uint64_t user=uint32_t(after.user-before.user);
  const uint64_t system=uint32_t(after.system-before.system);
  const uint64_t idle=uint32_t(after.idle-before.idle);
  const uint64_t nice=uint32_t(after.nice-before.nice);
  const uint64_t busy=user+system+nice;
  const uint64_t total=busy+idle;
  if(total==0) return false;
  percent=100.0*double(busy)/double(total);
  return true;
}

struct GPUState { std::string name; int64_t residency=0; };
inline bool gpuActivePercent(const std::vector<GPUState> &states,double &percent) {
  long double active=0, total=0;
  std::set<std::string> names;
  bool sawInactive=false, sawActive=false;
  for(const auto &state:states) {
    if(state.residency<0||!names.insert(state.name).second) return false;
    const bool idle=state.name=="OFF"||state.name=="IDLE"||state.name=="DOWN";
    bool performance=state.name.size()>1&&state.name[0]=='P';
    for(size_t i=1;performance&&i<state.name.size();i++)
      if(state.name[i]<'0'||state.name[i]>'9') performance=false;
    if(!idle&&!performance) return false;
    sawInactive=sawInactive||idle;
    sawActive=sawActive||performance;
    total+=state.residency;
    if(performance) active+=state.residency;
  }
  if(!sawInactive||!sawActive||total<=0) return false;
  percent=double(100*active/total);
  return true;
}

}
