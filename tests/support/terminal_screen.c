#include <stdint.h>
#include <string.h>
#include <vterm.h>

VTerm *adapter_screen_new(int rows, int cols)
{
  VTerm *term = vterm_new(rows, cols);
  if (term) {
    vterm_set_utf8(term, 1);
    VTermScreen *screen = vterm_obtain_screen(term);
    vterm_screen_enable_altscreen(screen, 1);
    vterm_screen_reset(screen, 1);
  }
  return term;
}

void adapter_screen_read(VTerm *term, uint32_t *cells)
{
  int rows;
  int cols;
  vterm_get_size(term, &rows, &cols);
  VTermScreen *screen = vterm_obtain_screen(term);
  for (int row = 0; row < rows; row++) {
    for (int col = 0; col < cols; col++) {
      VTermScreenCell cell = {0};
      vterm_screen_get_cell(screen, (VTermPos){row, col}, &cell);
      memcpy(cells, cell.chars, sizeof(cell.chars));
      cells[6] = (uint32_t)cell.width;
      cells[7] = cell.attrs.bold | (cell.attrs.reverse << 1) | (cell.attrs.underline << 2);
      cells += 8;
    }
  }
}

void adapter_screen_cursor(VTerm *term, int *position)
{
  VTermPos pos;
  vterm_state_get_cursorpos(vterm_obtain_state(term), &pos);
  position[0] = pos.row;
  position[1] = pos.col;
}
