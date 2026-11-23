// ViZDoom checked from C++: Freedoom's first level played a few hundred tics with a fixed
// plan of buttons, the state read as a program would give it to a model (the player's
// health, ammo and position, the objects in view), and the same seed and buttons played
// again to the same place. Built and run by test/doom.sh.
#include <ViZDoom.h>
#include <cstdio>
#include <string>
#include <vector>

using namespace vizdoom;

struct outcome
{
  double x, y, health, kills;
  size_t labels;
};

static outcome play(std::string const &vizdoom, unsigned seed, bool show)
{
  DoomGame game;
  game.setViZDoomPath(vizdoom + "/build/bin/vizdoom.app/Contents/MacOS/vizdoom"); // macOS: an app bundle
  game.setDoomGamePath(vizdoom + "/src/freedoom2.wad");
  game.setDoomMap("map01");
  game.setScreenResolution(RES_320X240);
  game.setWindowVisible(false);
  game.setSoundEnabled(false);
  game.setLabelsBufferEnabled(true);
  game.setAvailableButtons({ MOVE_FORWARD, TURN_LEFT, TURN_RIGHT, ATTACK, USE });
  game.setAvailableGameVariables({ HEALTH, AMMO2, POSITION_X, POSITION_Y, ANGLE, KILLCOUNT });
  game.setEpisodeTimeout(2100);
  game.setSeed(seed);
  game.setMode(PLAYER);
  game.init();
  game.newEpisode();
  std::vector<std::vector<double>> plan{ { 1, 0, 0, 0, 0 }, { 1, 1, 0, 0, 0 }, { 0, 0, 0, 1, 0 }, { 1, 0, 1, 0, 1 } };
  size_t labels{};
  for(int step{}; step < 80 && !game.isEpisodeFinished(); ++step)
  {
    auto const state(game.getState());
    labels = state->labels.size();
    if(show && step % 20 == 0)
    {
      auto const &v(state->gameVariables);
      std::printf("tic %d: health %.0f ammo %.0f at (%.0f, %.0f) facing %.0f; %zu objects in view:",
                  state->number, v[0], v[1], v[2], v[3], v[4], state->labels.size());
      for(auto const &l : state->labels)
      {
        std::printf(" %s (%.0f, %.0f)", l.objectName.c_str(), l.objectPositionX, l.objectPositionY);
      }
      std::printf("\n");
    }
    game.makeAction(plan[(step / 5) % plan.size()], 4); // the buttons held 4 tics
  }
  outcome o{ game.getGameVariable(POSITION_X), game.getGameVariable(POSITION_Y), game.getGameVariable(HEALTH),
             game.getGameVariable(KILLCOUNT), labels };
  game.close();
  return o;
}

int main(int, char **argv)
{
  std::string const vizdoom{ argv[1] };
  auto const a(play(vizdoom, 7, true));
  auto const b(play(vizdoom, 7, false));
  std::printf("end: (%.1f, %.1f) health %.0f kills %.0f; again with the same seed: (%.1f, %.1f) health %.0f kills %.0f\n",
              a.x, a.y, a.health, a.kills, b.x, b.y, b.health, b.kills);
  std::puts(a.x == b.x && a.y == b.y && a.health == b.health ? "ok: the same" : "DIFFERENT");
}
