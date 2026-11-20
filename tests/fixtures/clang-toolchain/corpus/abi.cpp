typedef float 向量类型 __attribute__((vector_size(32)));
向量类型 返回向量();
float 使用向量() { 向量类型 值 = 返回向量(); return 值[0]; }
