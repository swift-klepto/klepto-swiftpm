add_library(Klepto
    Klepto.swift
)

target_link_libraries(Klepto PUBLIC
  PackageModel
  Workspace
  SPMBuildCore
  Basics
)

set_target_properties(Klepto PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

if(USE_CMAKE_INSTALL)
install(TARGETS Klepto
  ARCHIVE DESTINATION lib
  LIBRARY DESTINATION lib
  RUNTIME DESTINATION bin)
endif()
set_property(GLOBAL APPEND PROPERTY SwiftPM_EXPORTS Klepto)
