// A small JSON parser for the files the engine reads: safetensors headers,
// manifests, config.json and tokenizer.json. Values are a tree of `json::value`.
#pragma once

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace inkling::json
{
  struct value;
  using object = std::vector<std::pair<std::string, value>>;
  using array = std::vector<value>;

  struct value
  {
    enum class kind : uint8_t
    {
      null,
      boolean,
      number,
      string,
      array,
      object
    };

    kind k{ kind::null };
    bool b{};
    double n{};
    std::string s;
    std::shared_ptr<json::array> a;
    std::shared_ptr<json::object> o;

    bool is_null() const { return k == kind::null; }
    bool is_object() const { return k == kind::object; }
    bool is_array() const { return k == kind::array; }
    bool is_string() const { return k == kind::string; }
    bool is_number() const { return k == kind::number; }

    value const *get(std::string_view key) const
    {
      if(k != kind::object)
      {
        return nullptr;
      }
      for(auto const &[name, v] : *o)
      {
        if(name == key)
        {
          return &v;
        }
      }
      return nullptr;
    }

    value const &at(std::string_view key) const
    {
      auto const v{ get(key) };
      if(!v)
      {
        throw std::runtime_error{ "json: missing key " + std::string{ key } };
      }
      return *v;
    }

    json::array const &items() const
    {
      if(k != kind::array)
      {
        throw std::runtime_error{ "json: not an array" };
      }
      return *a;
    }

    json::object const &fields() const
    {
      if(k != kind::object)
      {
        throw std::runtime_error{ "json: not an object" };
      }
      return *o;
    }

    double num() const
    {
      if(k != kind::number)
      {
        throw std::runtime_error{ "json: not a number" };
      }
      return n;
    }

    int64_t integer() const { return static_cast<int64_t>(num()); }

    std::string const &str() const
    {
      if(k != kind::string)
      {
        throw std::runtime_error{ "json: not a string" };
      }
      return s;
    }

    bool boolean_or(bool fallback) const { return k == kind::boolean ? b : fallback; }
  };

  namespace detail
  {
    struct parser
    {
      char const *p;
      char const *end;

      [[noreturn]] void fail(char const *what) const
      {
        throw std::runtime_error{ std::string{ "json: " } + what };
      }

      void ws()
      {
        while(p < end && (*p == ' ' || *p == '\n' || *p == '\r' || *p == '\t'))
        {
          ++p;
        }
      }

      static void put_utf8(std::string &out, uint32_t cp)
      {
        if(cp < 0x80)
        {
          out.push_back(static_cast<char>(cp));
        }
        else if(cp < 0x800)
        {
          out.push_back(static_cast<char>(0xc0 | (cp >> 6)));
          out.push_back(static_cast<char>(0x80 | (cp & 0x3f)));
        }
        else if(cp < 0x10000)
        {
          out.push_back(static_cast<char>(0xe0 | (cp >> 12)));
          out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3f)));
          out.push_back(static_cast<char>(0x80 | (cp & 0x3f)));
        }
        else
        {
          out.push_back(static_cast<char>(0xf0 | (cp >> 18)));
          out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3f)));
          out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3f)));
          out.push_back(static_cast<char>(0x80 | (cp & 0x3f)));
        }
      }

      uint32_t hex4()
      {
        if(end - p < 4)
        {
          fail("short \\u escape");
        }
        uint32_t v{};
        for(int i{}; i < 4; ++i)
        {
          char const c{ *p++ };
          v <<= 4;
          if(c >= '0' && c <= '9')
          {
            v |= static_cast<uint32_t>(c - '0');
          }
          else if(c >= 'a' && c <= 'f')
          {
            v |= static_cast<uint32_t>(c - 'a' + 10);
          }
          else if(c >= 'A' && c <= 'F')
          {
            v |= static_cast<uint32_t>(c - 'A' + 10);
          }
          else
          {
            fail("bad \\u escape");
          }
        }
        return v;
      }

      std::string string()
      {
        if(p >= end || *p != '"')
        {
          fail("expected string");
        }
        ++p;
        std::string out;
        while(true)
        {
          if(p >= end)
          {
            fail("unterminated string");
          }
          char const c{ *p++ };
          if(c == '"')
          {
            return out;
          }
          if(c != '\\')
          {
            out.push_back(c);
            continue;
          }
          if(p >= end)
          {
            fail("unterminated escape");
          }
          char const e{ *p++ };
          switch(e)
          {
            case '"':
              out.push_back('"');
              break;
            case '\\':
              out.push_back('\\');
              break;
            case '/':
              out.push_back('/');
              break;
            case 'b':
              out.push_back('\b');
              break;
            case 'f':
              out.push_back('\f');
              break;
            case 'n':
              out.push_back('\n');
              break;
            case 'r':
              out.push_back('\r');
              break;
            case 't':
              out.push_back('\t');
              break;
            case 'u':
              {
                uint32_t cp{ hex4() };
                if(cp >= 0xd800 && cp < 0xdc00 && end - p >= 6 && p[0] == '\\' && p[1] == 'u')
                {
                  p += 2;
                  uint32_t const lo{ hex4() };
                  cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
                }
                put_utf8(out, cp);
                break;
              }
            default:
              fail("bad escape");
          }
        }
      }

      value parse()
      {
        ws();
        if(p >= end)
        {
          fail("unexpected end");
        }
        value v;
        char const c{ *p };
        if(c == '{')
        {
          ++p;
          v.k = value::kind::object;
          v.o = std::make_shared<object>();
          ws();
          if(p < end && *p == '}')
          {
            ++p;
            return v;
          }
          while(true)
          {
            ws();
            auto key{ string() };
            ws();
            if(p >= end || *p != ':')
            {
              fail("expected ':'");
            }
            ++p;
            v.o->emplace_back(std::move(key), parse());
            ws();
            if(p < end && *p == ',')
            {
              ++p;
              continue;
            }
            if(p < end && *p == '}')
            {
              ++p;
              return v;
            }
            fail("expected ',' or '}'");
          }
        }
        if(c == '[')
        {
          ++p;
          v.k = value::kind::array;
          v.a = std::make_shared<array>();
          ws();
          if(p < end && *p == ']')
          {
            ++p;
            return v;
          }
          while(true)
          {
            v.a->push_back(parse());
            ws();
            if(p < end && *p == ',')
            {
              ++p;
              continue;
            }
            if(p < end && *p == ']')
            {
              ++p;
              return v;
            }
            fail("expected ',' or ']'");
          }
        }
        if(c == '"')
        {
          v.k = value::kind::string;
          v.s = string();
          return v;
        }
        if(c == 't' && end - p >= 4 && std::string_view{ p, 4 } == "true")
        {
          p += 4;
          v.k = value::kind::boolean;
          v.b = true;
          return v;
        }
        if(c == 'f' && end - p >= 5 && std::string_view{ p, 5 } == "false")
        {
          p += 5;
          v.k = value::kind::boolean;
          return v;
        }
        if(c == 'n' && end - p >= 4 && std::string_view{ p, 4 } == "null")
        {
          p += 4;
          return v;
        }
        char *num_end{};
        std::string const buf{ p, static_cast<size_t>(std::min<ptrdiff_t>(end - p, 64)) };
        v.n = std::strtod(buf.c_str(), &num_end);
        if(num_end == buf.c_str())
        {
          fail("unexpected character");
        }
        p += num_end - buf.c_str();
        v.k = value::kind::number;
        return v;
      }
    };
  }

  inline value parse(std::string_view text)
  {
    detail::parser ps{ text.data(), text.data() + text.size() };
    auto v{ ps.parse() };
    ps.ws();
    if(ps.p != ps.end)
    {
      ps.fail("trailing characters");
    }
    return v;
  }

  inline void escape_to(std::string &out, std::string_view s)
  {
    out.push_back('"');
    for(unsigned char const c : s)
    {
      switch(c)
      {
        case '"':
          out += "\\\"";
          break;
        case '\\':
          out += "\\\\";
          break;
        case '\n':
          out += "\\n";
          break;
        case '\r':
          out += "\\r";
          break;
        case '\t':
          out += "\\t";
          break;
        default:
          if(c < 0x20)
          {
            char buf[8];
            std::snprintf(buf, sizeof(buf), "\\u%04x", c);
            out += buf;
          }
          else
          {
            out.push_back(static_cast<char>(c));
          }
      }
    }
    out.push_back('"');
  }
}
