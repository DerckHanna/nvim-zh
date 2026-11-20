// Type conversion: implicit narrowing and invalid explicit conversion.
int narrowing() {
  long big = 1;
  int small = big;
  const char *text = 42;
  return small + text[0];
}

// Member lookup failure: the member does not exist on the type.
struct Holder {
  int present;
};

int missingMember(Holder holder) {
  return holder.absent;
}
