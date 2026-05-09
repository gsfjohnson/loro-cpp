use uniffi_bindgen::{backend::Literal, ComponentInterface};

use crate::bindings::cpp::{gen_cpp::filters::CppCodeOracle, CodeType};

#[derive(Debug)]
pub(crate) struct RecordCodeType {
    id: String,
}

impl RecordCodeType {
    pub(crate) fn new(id: String) -> Self {
        Self { id }
    }
}

impl CodeType for RecordCodeType {
    fn type_label(&self, _ci: &ComponentInterface) -> String {
        CppCodeOracle.class_name(&self.id)
    }

    fn canonical_name(&self) -> String {
        // Use the upper-camel-cased class name so the canonical name
        // matches the FfiConverter declaration that templates emit via
        // `ffi_converter_name|class_name`. Without this, raw UDL names
        // like `TreeID` produce inconsistent identifiers: declarations
        // become `FfiConverterSequenceTypeTreeId` (class_name applied)
        // but call sites become `FfiConverterSequenceTypeTreeID::lift`
        // (raw, unfiltered) → unresolved-identifier compile errors.
        format!("Type{}", CppCodeOracle.class_name(&self.id))
    }

    fn literal(&self, _literal: &Literal, _ci: &ComponentInterface) -> String {
        unreachable!();
    }
}
