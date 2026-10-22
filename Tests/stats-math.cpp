// Run with Tests/run.sh. Checks the residency math behind the clock and ANE rows.
#include "../NativeHUD/stats/usage_math.hpp"
#include "../NativeHUD/stats/telemetry.hpp"
#include "../NativeHUD/stats/power_math.hpp"
#include <cassert>
#include <cmath>
#include <cstdio>
using namespace hudstats::usage;

int main() {
  // State names as macOS 27 reports them on an M4 Max.
  assert(frequencyIndex("V0P6")==0 && frequencyIndex("V19P0")==19 && frequencyIndex("P15")==15);
  assert(frequencyIndex("IDLE")==-1 && frequencyIndex("DOWN")==-1 && frequencyIndex("OFF")==-1);
  assert(frequencyIndex("P")==-1 && frequencyIndex("V3")==-1 && frequencyIndex("P2x")==-1 && frequencyIndex("VMIN")==-1);

  const std::vector<double> table{1000,2000,3000};
  double mhz=-1;
  assert(activeClock({{"IDLE",50},{"V0P2",25},{"V2P0",25}},table,mhz) && mhz==2000);
  assert(activeClock({{"IDLE",100},{"V1P1",0}},table,mhz) && mhz==0); // idle all interval
  assert(!activeClock({{"V3P0",1}},table,mhz));                       // table does not fit the chip
  const std::vector<double> gpu{0,338,618};                            // index 0 is the OFF slot
  assert(activeClock({{"OFF",10},{"P1",30},{"P2",10}},gpu,mhz) && std::fabs(mhz-408)<0.001);

  double percent=-1;
  assert(raisedFloorPercent({{"VMIN",70},{"VNOM",20},{"VMAX",10}},percent) && std::fabs(percent-30)<1e-9);
  assert(raisedFloorPercent({{"F1",100},{"F2",0}},percent) && percent==0);
  assert(!raisedFloorPercent({{"VMIN",1}},percent) && !raisedFloorPercent({{"F1",0},{"F2",0}},percent));

  assert(gpuActivePercent({{"OFF",40},{"P1",30},{"P2",30}},percent) && percent==60);
  // Temperatures: power-gated sensors park at exactly 40.0; known core keys report the hottest, others the mean.
  using hudstats::temperatureHeadline;
  assert(!hudstats::plausibleCelsius(40.0f) && !hudstats::plausibleCelsius(5.2f) && !hudstats::plausibleCelsius(NAN));
  float c=0;
  assert(temperatureHeadline({52,40,67,40,61},true,c) && c==67);
  assert(temperatureHeadline({50,40,60},false,c) && c==55);
  assert(!temperatureHeadline({40,40,-4,0},true,c));
  // CPU power: a power-gated cluster (no residency) is 0 W, not a failed reading.
  double watts=-1;
  assert(hudstats::power::weightedWatts({{" 2W",3},{" 4W",1}},watts) && watts==2.5);
  assert(hudstats::power::weightedWatts({{" 0.250W",0},{" 0.500W",0}},watts) && watts==0);
  assert(!hudstats::power::weightedWatts({{"bogus",1}},watts));
  puts("stats math: all checks passed");
}
