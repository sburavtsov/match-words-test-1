components {
  id: "script"
  component: "/screens/meta_anagram/cell.script"
}
embedded_components {
  id: "character"
  type: "label"
  data: "size {\n"
  "  x: 256.0\n"
  "  y: 256.0\n"
  "}\n"
  "text: \"\\320\\256\"\n"
  "font: \"/assets/fonts/anagram.font\"\n"
  "material: \"/builtins/fonts/label-df.material\"\n"
  ""
  position {
    z: 0.1
  }
  scale {
    x: 6.0
    y: 6.0
  }
}
embedded_components {
  id: "back"
  type: "sprite"
  data: "default_animation: \"chip_back\"\n"
  "material: \"/shaders/color_sprite/recolor.material\"\n"
  "textures {\n"
  "  sampler: \"texture_sampler\"\n"
  "  texture: \"/assets/game.atlas\"\n"
  "}\n"
  ""
}