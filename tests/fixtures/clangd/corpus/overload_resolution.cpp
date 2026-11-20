// Overload resolution: no viable candidate and wrong argument count.
struct Overloads {
  int operator()(int value) const;
  int operator()(int first, int second) const;
};

int pick(Overloads overloads) {
  overloads(1, 2, 3);
  return overloads();
}
