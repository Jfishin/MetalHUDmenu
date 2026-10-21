#pragma once
#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

namespace hudstats::power {
struct Bucket { std::string label; int64_t residency; };

inline bool bucketWatts(const std::string &label,double &watts) {
  const char *first=label.c_str();
  while(*first==' '||*first=='\t') first++;
  bool any=false;
  long double parsed=0, fraction=0.1;
  while(*first>='0'&&*first<='9') { parsed=parsed*10+(*first++-'0'); any=true; if(parsed>1000) return false; }
  if(*first=='.') {
    first++;
    while(*first>='0'&&*first<='9') { parsed+=(*first++-'0')*fraction; fraction*=0.1; any=true; }
  }
  if(!any||*first!='W') return false;
  first++;
  while(*first==' '||*first=='\t') first++;
  if(*first||parsed<0||parsed>1000) return false;
  watts=(double)parsed;
  return true;
}

inline bool weightedWatts(const std::vector<Bucket> &buckets,double &watts) {
  if(buckets.empty()) return false;
  long double weighted=0, total=0;
  for(const auto &bucket:buckets) {
    double label=0;
    if(bucket.residency<0||!bucketWatts(bucket.label,label)) return false;
    weighted+=(long double)label*bucket.residency;
    total+=bucket.residency;
  }
  if(total<=0) return false;
  watts=(double)(weighted/total);
  return std::isfinite(watts)&&watts>=0;
}

inline bool energyWatts(int64_t delta,const std::string &unit,double elapsed,double &watts) {
  if(delta<=0||!std::isfinite(elapsed)||elapsed<=0||elapsed>3.5) return false;
  double scale=unit=="mJ"?1e3:unit=="uJ"?1e6:unit=="nJ"?1e9:0;
  if(scale==0) return false;
  watts=delta/scale/elapsed;
  return std::isfinite(watts)&&watts>0&&watts<1000;
}
} // namespace hudstats::power
