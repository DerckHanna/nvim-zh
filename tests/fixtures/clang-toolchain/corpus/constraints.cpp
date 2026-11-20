template <typename T> concept 可加 = requires(T a, T b) { a + b; };
template <可加 T> T 求和(T a, T b) { return a + b; }
struct 不可加 {};
int 主函数() { 不可加 值; return 求和(值, 值); }
