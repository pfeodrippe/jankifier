// The frontend checked on a tiny NES program written here: it reads the controller in a loop
// (into $03, then the whole byte into $00) and counts frames (NMI) in $02. Built and run by test/run.sh.
#include <play/nes.hpp>
#include <cassert>
#include <cstdio>
#include <fstream>

static void write_rom(char const *path)
{
  std::vector<uint8_t> rom(16 + 16384 + 8192, 0);
  uint8_t const header[]{ 'N', 'E', 'S', 0x1a, 1, 1, 0, 0 };
  std::copy(std::begin(header), std::end(header), rom.begin());
  uint8_t const code[]{
    0x78, 0xd8, 0xa2, 0xff, 0x9a, 0xa9, 0x80, 0x8d, 0x00, 0x20, // sei cld ldx #$ff txs; NMI on
    0xa9, 0x01, 0x8d, 0x16, 0x40, 0xa9, 0x00, 0x8d, 0x16, 0x40, // loop: strobe the controller
    0xa9, 0x00, 0x85, 0x03,                                     // lda #0 sta $03
    0xa2, 0x08,                                                 // ldx #8
    0xad, 0x16, 0x40, 0x4a, 0x26, 0x03, 0xca, 0xd0, 0xf7,       // read: lda $4016 lsr rol $03 dex bne read
    0xa5, 0x03, 0x85, 0x00,                                     // lda $03 sta $00: the byte whole
    0x4c, 0x0a, 0x80,                                           // jmp loop
    0xe6, 0x02, 0x40                                            // nmi: inc $02 rti
  };
  std::copy(std::begin(code), std::end(code), rom.begin() + 16);
  uint8_t const vectors[]{ 0x2a, 0x80, 0x00, 0x80, 0x00, 0x80 }; // NMI $802a, reset and IRQ $8000
  std::copy(std::begin(vectors), std::end(vectors), rom.begin() + 16 + 0x3ffa);
  std::ofstream{ path, std::ios::binary }.write(reinterpret_cast<char const *>(rom.data()), rom.size());
}

int main(int argc, char **argv)
{
  char const *rom{ "/private/tmp/play-test.nes" };
  write_rom(rom);
  play::nes n{ argv[1] };
  n.load(rom);
  n.run(0, 10);
  std::printf("ram %zu bytes; picture %ux%u; after 10 frames: $00=%02x $02=%u\n", n.ram_size(), n.width(), n.height(), n.ram()[0], n.ram()[2]);
  n.run(play::a | play::right, 2);
  std::printf("A and right held: $00=%02x (A is bit 7, right bit 0)\n", n.ram()[0]);
  assert(n.ram()[0] == 0x81);
  n.run(play::start, 1);
  assert(n.ram()[0] == 0x10);
  auto const saved(n.save());
  uint8_t const frames_then{ n.ram()[2] };
  n.run(play::b, 30);
  uint8_t const frames_later{ n.ram()[2] };
  n.restore(saved);
  assert(n.ram()[2] == frames_then);
  n.run(play::b, 30);
  assert(n.ram()[2] == frames_later);
  std::printf("frames counted %u -> %u; restored and run again: the same (%u); state %zu bytes\n", frames_then, frames_later, n.ram()[2], saved.size());
  std::puts("ok");
}
