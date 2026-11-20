// Template instantiation: the note chain points at the instantiation site.
template <typename T> struct Holder {
  T value;
};

template <typename T> struct Wrapper {
  Holder<T> inner;
};

template <typename T> T twice(T input) {
  return input + input;
}

// Instantiating with an incomplete or mismatched type makes clang report the
// instantiation context in a note.
int instantiate() {
  Wrapper<Holder<int>> wrapper{};
  return twice(wrapper.inner.value);
}
