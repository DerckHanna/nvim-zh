#include <iostream>
#include <vector>

int main(){
	std::cout << "Test 1" << std::endl;
	std::vector<int> vec_int;
	for(int i = 0;i < 5;i++){
		vec_int.emplace_back(i);
	}
	return 0;
}
