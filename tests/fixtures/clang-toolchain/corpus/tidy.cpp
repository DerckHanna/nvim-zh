#include <cstdlib>
#include <fcntl.h>
#include <utility>
struct 配置 {
  int *指针 = 0;
};
int 处理(int 参数) {
  if (参数 < 0) {
    return 1;
  } else {
    return 2;
  }
}
void 末尾返回() {
  int 值 = 3;
  (void)值;
  return;
}
void 交换(int 左, int 右) {
  std::swap(左, 右);
}
void 清理(void *缓冲) {
  std::free(缓冲);
}
int 相加(int 左值, int 右值) {
  return 左值 + 右值;
}
void 未用参数(int 未用) {
  return;
}
int 相邻(int 左, int 右) {
  if (左 < 100)
    return 1;
  return 右 * 100;
}
struct LongerType {};
void 自动推导() {
  LongerType *对象 = new LongerType;
  delete 对象;
}
int 打开() { return open("路径.txt", O_RDONLY); }
