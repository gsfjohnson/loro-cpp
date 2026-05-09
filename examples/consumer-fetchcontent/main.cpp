// Minimal consumer that links loro::loro from a find_package or FetchContent
// integration. Round-trips a snapshot through a fresh doc to confirm the
// generated bindings + Rust archive + system libs are all wired correctly.

#include <loro.hpp>
#include <loro/loro_ext.hpp>

#include <iostream>

namespace ext = loro::ext;

int main() {
    auto doc = loro::LoroDoc::init();
    auto text = doc->get_text(ext::root("body"));
    text->insert(0, "consumer ok");

    auto snapshot = doc->export_snapshot();
    auto fresh = loro::LoroDoc::init();
    fresh->import(snapshot);

    auto reread = fresh->get_text(ext::root("body"))->to_string();
    if (reread != "consumer ok") {
        std::cerr << "round-trip mismatch: " << reread << "\n";
        return 1;
    }
    std::cout << "consumer round-trip: " << reread << "\n";
    return 0;
}
