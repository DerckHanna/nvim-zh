struct Widget {
  explicit Widget(int);
};

void no_default_constructor() { Widget value; }
void narrowing_conversion() { int values[] = {3.5}; }
void const_pointer(const int *address) { *address = 3; }
