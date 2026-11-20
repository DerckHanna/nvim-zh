#ifdef __cplusplus
extern "C"
#endif
int undefined_at_link(void);
int main(void) { return undefined_at_link(); }
