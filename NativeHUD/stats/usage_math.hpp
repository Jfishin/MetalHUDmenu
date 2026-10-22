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

// One IOReport state and its residency over a sample interval.
struct State { std::string name; int64_t residency=0; };

inline bool gpuActivePercent(const std::vector<State> &states,double &percent) {
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

// pmgr frequency-table index of an active performance state:
// CPU complexes name them "V<i>P<j>", the GPU "P<i>". Idle states (OFF/IDLE/DOWN) give -1.
inline int frequencyIndex(const std::string &name) {
  if(name.size()<2||(name[0]!='V'&&name[0]!='P')) return -1;
  size_t i=1; int index=0;
  while(i<name.size()&&name[i]>='0'&&name[i]<='9'&&index<1000) index=index*10+(name[i++]-'0');
  if(i==1) return -1;
  if(name[0]=='P') return i==name.size()?index:-1;
  return i+1<name.size()&&name[i]=='P'?index:-1;
}

// Residency-weighted clock while active, in the table's unit. 0 means idle the whole interval.
// False when a state falls outside the table: an unverified chip layout.
inline bool activeClock(const std::vector<State> &states,const std::vector<double> &table,double &clock) {
  long double weighted=0, active=0;
  for(const auto &state:states) {
    const int index=frequencyIndex(state.name);
    if(index<0) continue;
    if(index>=(int)table.size()||state.residency<0) return false;
    weighted+=(long double)table[(size_t)index]*state.residency;
    active+=state.residency;
  }
  clock=active>0?double(weighted/active):0;
  return true;
}

// Share of time a PMP floor channel requests more than its lowest step (VMIN, F1, ...).
// Used for the ANE, whose energy counters read 0 on macOS 27 (same idea as mactop).
inline bool raisedFloorPercent(const std::vector<State> &states,double &percent) {
  if(states.size()<2) return false;
  long double raised=0, total=0;
  for(size_t i=0;i<states.size();i++) {
    if(states[i].residency<0) return false;
    total+=states[i].residency;
    if(i>0) raised+=states[i].residency;
  }
  if(total<=0) return false;
  percent=double(100*raised/total);
  return true;
}

}
