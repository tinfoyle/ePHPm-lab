<?php
/**
 * Plugin Name: ePHPm Lab v5 Benchmark Helpers
 * Description: Small observability endpoints used only by the throwaway WooCommerce fixture.
 */

add_action( 'rest_api_init', static function (): void {
    register_rest_route(
        'ephpm-lab/v1',
        '/runtime',
        array(
            'methods'             => 'GET',
            'permission_callback' => '__return_true',
            'callback'            => static function (): WP_REST_Response {
                global $wp_object_cache;

                return new WP_REST_Response(
                    array(
                        'cache_class' => is_object( $wp_object_cache ) ? get_class( $wp_object_cache ) : gettype( $wp_object_cache ),
                        'native_kv'   => function_exists( 'ephpm_kv_get' ),
                        'redis'       => class_exists( 'Redis' ),
                        'woocommerce' => class_exists( 'WooCommerce' ),
                        'elementor'   => did_action( 'elementor/loaded' ) > 0,
                    )
                );
            },
        )
    );

    register_rest_route(
        'ephpm-lab/v1',
        '/cache-check',
        array(
            'methods'             => 'GET',
            'permission_callback' => '__return_true',
            'callback'            => static function (): WP_REST_Response {
                $key = 'v5-cache-check';
                wp_cache_set( $key, 'ok', 'ephpm-lab', 300 );

                return new WP_REST_Response(
                    array(
                        'value' => wp_cache_get( $key, 'ephpm-lab' ),
                        'group' => 'ephpm-lab',
                    )
                );
            },
        )
    );

    register_rest_route(
        'ephpm-lab/v1',
        '/cart-products',
        array(
            'methods'             => 'GET',
            'permission_callback' => '__return_true',
            'callback'            => static function (): WP_REST_Response {
                $products = array();
                foreach ( array( 'bench-simple-0001', 'bench-simple-0002' ) as $slug ) {
                    $post = get_page_by_path( $slug, OBJECT, 'product' );
                    if ( $post ) {
                        $products[] = array(
                            'id'   => (int) $post->ID,
                            'name' => $post->post_title,
                        );
                    }
                }

                return new WP_REST_Response( array( 'products' => $products ) );
            },
        )
    );
} );

// Orders are fixture data, not outbound integration tests. Prevent the
// WooCommerce status transition from attempting local sendmail delivery.
add_filter( 'pre_wp_mail', static function () {
    return true;
} );
