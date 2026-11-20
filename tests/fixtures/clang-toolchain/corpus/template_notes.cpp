template <class T, class U> struct Pair {};
Pair<int> 和;
template <class T> concept C = requires { typename T::value_type; };
template <C T> void require(T);
void test() { require(0); }
struct Tag;
void use(Tag *t) { t->foo(); }
using narrow_t = long long;
void take(int *);
void bad() { take(narrow_t{}); }
