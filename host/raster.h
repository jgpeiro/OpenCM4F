#pragma once
#include <stdint.h>
/* estimated clocks: per skipped command 1, per active command GPU_COST_ACTIVE, per text character
   GPU_COST_CHAR, per pixel 1 (the RTL reports the real numbers); a line has 3120 clocks */
#define GPU_COST_ACTIVE 4
#define GPU_COST_CHAR 2
int raster_line(const uint32_t *dl, const uint32_t *gd, const uint32_t *img, const uint16_t *pal, uint16_t bg, int y,
                uint16_t *line);
int raster_frame(const uint32_t *dl, const uint32_t *gd, const uint32_t *img, const uint16_t *pal, uint16_t bg,
                 uint16_t *fb);
