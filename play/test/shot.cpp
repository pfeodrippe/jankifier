// A game run in the emulator with a plan of buttons, and its picture saved at chosen frames
// (as PPM), to see that it runs: shot <core> <game.nes> <out-prefix> [frame:buttons ...]
// where buttons is a word of the letters a b s(elect) t(start) u d l r, held from that frame.
#include <play/nes.hpp>
#include <cstdio>
#include <map>
#include <string>

static unsigned parse(std::string const &w)
{
  unsigned b{};
  for(char c : w)
  {
    switch(c)
    {
      case 'a': b |= play::a; break;
      case 'b': b |= play::b; break;
      case 's': b |= play::select; break;
      case 't': b |= play::start; break;
      case 'u': b |= play::up; break;
      case 'd': b |= play::down; break;
      case 'l': b |= play::left; break;
      case 'r': b |= play::right; break;
      default: break;
    }
  }
  return b;
}

int main(int argc, char **argv)
{
  play::nes n{ argv[1] };
  n.load(argv[2]);
  std::string const out{ argv[3] };
  std::map<unsigned, unsigned> plan;
  unsigned last{};
  for(int i{ 4 }; i < argc; ++i)
  {
    std::string const arg{ argv[i] };
    auto const colon(arg.find(':'));
    unsigned const frame(std::stoul(arg.substr(0, colon)));
    plan[frame] = parse(arg.substr(colon + 1));
    last = frame;
  }
  unsigned buttons{};
  int shots{};
  for(unsigned f{}; f <= last + 60; ++f)
  {
    if(auto const it(plan.find(f)); it != plan.end())
    {
      buttons = it->second;
    }
    n.run(buttons);
    if(f > 0 && (f % 120 == 0 || f == last + 60))
    {
      auto const name(out + "-" + std::to_string(f) + ".ppm");
      auto file(std::fopen(name.c_str(), "wb"));
      std::fprintf(file, "P6\n%u %u\n255\n", n.width(), n.height());
      for(auto const p : n.picture())
      {
        unsigned char const rgb[]{ static_cast<unsigned char>(p >> 16), static_cast<unsigned char>(p >> 8),
                                   static_cast<unsigned char>(p) };
        std::fwrite(rgb, 1, 3, file);
      }
      std::fclose(file);
      ++shots;
    }
  }
  std::printf("%u frames, %d pictures\n", last + 61, shots);
}
