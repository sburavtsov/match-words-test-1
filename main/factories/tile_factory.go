components {
  id: "script"
  component: "/main/factories/tile.script"
}
embedded_components {
  id: "character"
  type: "label"
  data: "size {\n"
  "  x: 256.0\n"
  "  y: 256.0\n"
  "}\n"
  "text: \"\\320\\256\"\n"
  "font: \"/assets/fonts/rum.font\"\n"
  "material: \"/builtins/fonts/label-df.material\"\n"
  ""
  position {
    z: 0.1
  }
  scale {
    x: 10.0
    y: 10.0
  }
}
embedded_components {
  id: "back"
  type: "sprite"
  data: "default_animation: \"chip-back\"\n"
  "material: \"/shaders/color_sprite/recolor.material\"\n"
  "textures {\n"
  "  sampler: \"texture_sampler\"\n"
  "  texture: \"/assets/grind.atlas\"\n"
  "}\n"
  ""
}
