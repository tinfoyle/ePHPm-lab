<?php

if ( get_option( 'ephpm_lab_v5_seed_version' ) === '1' ) {
    WP_CLI::success( 'v5 fixture already seeded.' );
    return;
}

if ( ! class_exists( 'WooCommerce' ) ) {
    WP_CLI::error( 'WooCommerce is not active.' );
}

function v5_term( string $name, string $taxonomy ): int {
    $existing = term_exists( $name, $taxonomy );
    if ( $existing ) {
        return (int) ( is_array( $existing ) ? $existing['term_id'] : $existing );
    }

    $created = wp_insert_term( $name, $taxonomy );
    if ( is_wp_error( $created ) ) {
        WP_CLI::error( $created->get_error_message() );
    }

    return (int) $created['term_id'];
}

$category_ids = array();
for ( $i = 1; $i <= 15; $i++ ) {
    $category_ids[] = v5_term( sprintf( 'Bench Category %02d', $i ), 'product_cat' );
}

$tag_ids = array();
for ( $i = 1; $i <= 30; $i++ ) {
    $tag_ids[] = v5_term( sprintf( 'Bench Tag %02d', $i ), 'product_tag' );
}

foreach ( array( 'color', 'size', 'material' ) as $attribute ) {
    if ( ! taxonomy_exists( 'pa_' . $attribute ) ) {
        wc_create_attribute(
            array(
                'name'         => ucfirst( $attribute ),
                'slug'         => $attribute,
                'type'         => 'select',
                'order_by'     => 'menu_order',
                'has_archives' => true,
            )
        );
        delete_transient( 'wc_attribute_taxonomies' );
        register_taxonomy(
            'pa_' . $attribute,
            array( 'product' ),
            array( 'hierarchical' => false, 'show_ui' => false, 'query_var' => true, 'rewrite' => false )
        );
    }
}

$image_dir  = WP_CONTENT_DIR . '/uploads';
$image_file = $image_dir . '/bench-product.svg';
wp_mkdir_p( $image_dir );
file_put_contents(
    $image_file,
    '<svg xmlns="http://www.w3.org/2000/svg" width="800" height="800"><rect width="800" height="800" fill="#0f766e"/><rect x="80" y="80" width="640" height="640" fill="#f8fafc"/><text x="400" y="390" text-anchor="middle" font-family="Arial" font-size="52" fill="#0f766e">BENCH</text><text x="400" y="455" text-anchor="middle" font-family="Arial" font-size="34" fill="#475569">WooCommerce</text></svg>'
);

$attachment_id = attachment_url_to_postid( content_url( 'uploads/bench-product.svg' ) );
if ( ! $attachment_id ) {
    $attachment_id = wp_insert_attachment(
        array(
            'post_mime_type' => 'image/svg+xml',
            'post_title'     => 'Bench Product',
            'post_status'    => 'inherit',
        ),
        $image_file
    );
}

$simple_count = 1000;
for ( $i = 1; $i <= $simple_count; $i++ ) {
    $sku = sprintf( 'BENCH-S-%04d', $i );
    if ( wc_get_product_id_by_sku( $sku ) ) {
        continue;
    }

    $product = new WC_Product_Simple();
    $product->set_name( sprintf( 'Bench Simple Product %04d', $i ) );
    $product->set_slug( sprintf( 'bench-simple-%04d', $i ) );
    $product->set_sku( $sku );
    $product->set_regular_price( (string) ( 15 + ( $i % 240 ) ) );
    $product->set_sale_price( $i % 4 === 0 ? (string) ( 10 + ( $i % 180 ) ) : '' );
    $product->set_stock_status( 'instock' );
    $product->set_catalog_visibility( 'visible' );
    $product->set_description( 'A deterministic benchmark product with enough body copy to exercise WooCommerce templates, metadata, related products, and schema output.' );
    $product->set_short_description( 'Fixture product ' . $i );
    $product->set_category_ids( array( $category_ids[ $i % count( $category_ids ) ] ) );
    $product->set_tag_ids( array( $tag_ids[ $i % count( $tag_ids ) ], $tag_ids[ ( $i + 7 ) % count( $tag_ids ) ] ) );
    $product->set_image_id( $attachment_id );
    $product->save();
}

$colors = array( 'Teal', 'Slate', 'Sand', 'Coral' );
$sizes  = array( 'Small', 'Medium', 'Large', 'XL' );
foreach ( $colors as $color ) {
    v5_term( $color, 'pa_color' );
}
foreach ( $sizes as $size ) {
    v5_term( $size, 'pa_size' );
}

for ( $i = 1; $i <= 200; $i++ ) {
    $sku = sprintf( 'BENCH-V-%04d', $i );
    if ( wc_get_product_id_by_sku( $sku ) ) {
        continue;
    }

    $product = new WC_Product_Variable();
    $product->set_name( sprintf( 'Bench Variable Product %04d', $i ) );
    $product->set_slug( sprintf( 'bench-variable-%04d', $i ) );
    $product->set_sku( $sku );
    $product->set_stock_status( 'instock' );
    $product->set_catalog_visibility( 'visible' );
    $product->set_description( 'A variable benchmark product that exercises variation lookup, attribute taxonomies, price ranges, and related-product queries.' );
    $product->set_category_ids( array( $category_ids[ $i % count( $category_ids ) ] ) );
    $product->set_tag_ids( array( $tag_ids[ $i % count( $tag_ids ) ] ) );
    $product->set_image_id( $attachment_id );

    $color_attribute = new WC_Product_Attribute();
    $color_attribute->set_id( wc_attribute_taxonomy_id_by_name( 'pa_color' ) );
    $color_attribute->set_name( 'pa_color' );
    $color_attribute->set_options( array_map( 'v5_term', $colors, array_fill( 0, count( $colors ), 'pa_color' ) ) );
    $color_attribute->set_visible( true );
    $color_attribute->set_variation( true );

    $size_attribute = new WC_Product_Attribute();
    $size_attribute->set_id( wc_attribute_taxonomy_id_by_name( 'pa_size' ) );
    $size_attribute->set_name( 'pa_size' );
    $size_attribute->set_options( array_map( 'v5_term', $sizes, array_fill( 0, count( $sizes ), 'pa_size' ) ) );
    $size_attribute->set_visible( true );
    $size_attribute->set_variation( true );

    $product->set_attributes( array( $color_attribute, $size_attribute ) );
    $product_id = $product->save();

    for ( $variation = 0; $variation < 4; $variation++ ) {
        $child = new WC_Product_Variation();
        $child->set_parent_id( $product_id );
        $child->set_sku( sprintf( '%s-%02d', $sku, $variation + 1 ) );
        $child->set_regular_price( (string) ( 45 + $i + $variation ) );
        $child->set_stock_status( 'instock' );
        $child->set_attributes(
            array(
                'pa_color' => sanitize_title( $colors[ $variation ] ),
                'pa_size'  => sanitize_title( $sizes[ $variation ] ),
            )
        );
        $child->save();
    }
}

$author_id = (int) get_current_user_id();
if ( ! $author_id ) {
    $author_id = 1;
}

for ( $i = 1; $i <= 300; $i++ ) {
    $slug = sprintf( 'bench-journal-%04d', $i );
    if ( get_page_by_path( $slug, OBJECT, 'post' ) ) {
        continue;
    }
    wp_insert_post(
        array(
            'post_title'   => sprintf( 'Benchmark Journal Entry %04d', $i ),
            'post_name'    => $slug,
            'post_content' => str_repeat( 'This generated benchmark article exercises WordPress content filters, SEO metadata, theme templates, widgets, and related queries. ', 12 ),
            'post_status'  => 'publish',
            'post_type'    => 'post',
            'post_author'  => $author_id,
        )
    );
}

$front_page = get_page_by_path( 'benchmark-storefront', OBJECT, 'page' );
if ( ! $front_page ) {
    $front_id = wp_insert_post(
        array(
            'post_title'   => 'Benchmark Storefront',
            'post_name'    => 'benchmark-storefront',
            'post_content' => '<h2>Featured benchmark products</h2>[products limit="24" columns="4" visibility="featured"]<h2>Latest arrivals</h2>[products limit="16" columns="4" orderby="date"]',
            'post_status'  => 'publish',
            'post_type'    => 'page',
            'post_author'  => $author_id,
        )
    );
    update_post_meta( $front_id, '_elementor_edit_mode', 'builder' );
    update_post_meta( $front_id, '_elementor_template_type', 'wp-page' );
    update_post_meta( $front_id, '_elementor_data', '[{"id":"v5hero","elType":"container","settings":{},"elements":[{"id":"v5heading","elType":"widget","widgetType":"heading","settings":{"title":"Benchmark Storefront"},"elements":[]}]}]' );
    update_option( 'show_on_front', 'page' );
    update_option( 'page_on_front', $front_id );
}

if ( ! get_page_by_path( 'contact', OBJECT, 'page' ) ) {
    wp_insert_post(
        array(
            'post_title'   => 'Contact',
            'post_name'    => 'contact',
            'post_content' => '[contact-form-7 title="Benchmark Contact"]',
            'post_status'  => 'publish',
            'post_type'    => 'page',
        )
    );
}

$review_products = wc_get_products( array( 'limit' => 100, 'return' => 'ids', 'status' => 'publish' ) );
for ( $i = 1; $i <= 2000; $i++ ) {
    $product_id = $review_products[ $i % count( $review_products ) ];
    wp_insert_comment(
        array(
            'comment_post_ID'      => $product_id,
            'comment_author'       => 'Bench Reviewer ' . $i,
            'comment_author_email' => 'reviewer' . $i . '@example.test',
            'comment_content'      => 'This deterministic review adds real comment, rating, and aggregate metadata work to product pages.',
            'comment_type'         => 'review',
            'comment_approved'     => 1,
            'comment_date'         => gmdate( 'Y-m-d H:i:s', time() - ( $i * 120 ) ),
        )
    );
}

for ( $i = 1; $i <= 200; $i++ ) {
    $order = wc_create_order();
    $product_id = $review_products[ $i % count( $review_products ) ];
    $order->add_product( wc_get_product( $product_id ), 1 );
    $order->set_address(
        array(
            'first_name' => 'Bench',
            'last_name'  => 'Customer ' . $i,
            'email'      => 'customer' . $i . '@example.test',
            'address_1'  => '123 Benchmark Way',
            'city'       => 'Testville',
            'state'      => 'CA',
            'postcode'   => '94107',
            'country'    => 'US',
        ),
        'billing'
    );
    $order->calculate_totals();
    $order->update_status( 'completed' );
}

wp_set_object_terms( 0, array(), 'category' );
wc_delete_product_transients();
wp_cache_flush();
update_option( 'ephpm_lab_v5_seed_version', '1', false );
WP_CLI::success( 'Seeded WordPress v5 WooCommerce fixture.' );
