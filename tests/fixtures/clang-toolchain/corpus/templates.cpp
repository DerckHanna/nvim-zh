#include <vector>
template <typename T> requires requires(T t) { t + 1; }
T 加一(T 值) { return 值 + 1; }
struct 甲 { int 成员; };
int 使用() {
  std::vector<int> 容器;
  容器.不存在();
  甲 对象;
  return 对象.别的成员 + 加一(对象);
}
