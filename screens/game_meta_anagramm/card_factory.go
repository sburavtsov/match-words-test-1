components {
  id: "script"
  component: "/screens/game_meta_anagramm/card.script"
}
embedded_components {
  id: "character"
  type: "label"
  data: "size {\n"
  "  x: 256.0\n"
  "  y: 256.0\n"
  "}\n"
  "text: \"A\"\n"
  "font: \"/assets/fonts/unisans.font\"\n"
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
  data: "default_animation: \"chip-back\"\n"
  "material: \"/shaders/color_sprite/recolor.material\"\n"
  "textures {\n"
  "  sampler: \"texture_sampler\"\n"
  "  texture: \"/assets/grind.atlas\"\n"
  "}\n"
  ""
}