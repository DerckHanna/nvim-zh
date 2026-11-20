// Cross-file note: the definition lives in another translation unit.
extern int sharedDeclaration();

int crossFileNote() {
  return sharedDeclaration() + sharedDeclaration();
}
